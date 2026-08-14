<#
.SYNOPSIS
    Capture Fabric artifact IDs from a workspace.

.DESCRIPTION
    Lists workspace items using Fabric CLI and captures metadata for data objects
    (Lakehouse, Warehouse, Dataflow, etc.), including SQL endpoint properties for
    Lakehouses. Optionally updates parameter.yml with dynamic fabric-cicd
    find_replace tokens. Dataflow references found in mashup.pq are emitted as
    regex replacements with Dataflow item and file_path filters so they can be
    resolved with $items.Dataflow.<name>.$id.

.PARAMETER WorkspaceName
    Fabric workspace name to capture artifacts from.

.PARAMETER OutputPath
    Output path for artifact_mapping.json. Defaults to <script-dir>/artifact_mapping.json.

.PARAMETER UpdateParameterYml
    Switch to update parameter.yml with find_replace entries.

.PARAMETER ParameterYmlPath
    Path to parameter.yml. Defaults to <repo-root>/parameter.yml.

.EXAMPLE
    .\capture_artifact_ids.ps1 -WorkspaceName "cicd-conn-mgmt-dev" -OutputPath ".\artifact_mapping.json"

.EXAMPLE
    .\capture_artifact_ids.ps1 -WorkspaceName "cicd-conn-mgmt-dev" `
        -UpdateParameterYml -ParameterYmlPath ".\parameter.yml"
#>

param(
    [Parameter(Mandatory)][string]$WorkspaceName,
    [string]$OutputPath,
    [switch]$UpdateParameterYml,
    [string]$ParameterYmlPath
)

$ErrorActionPreference = 'Stop'

# Parse JSON emitted by the Fabric CLI, tolerating any non-JSON status/warning
# lines the CLI may print before the payload (e.g. "Unable to ...", spinners).
# Returns $null when no JSON object/array can be found in the output.
function ConvertFrom-FabJson {
    param([Parameter(ValueFromPipeline)][string[]]$Raw)
    $text = ($Raw -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $start = $text.IndexOfAny([char[]]@('{', '['))
    if ($start -lt 0) { return $null }
    $end = [Math]::Max($text.LastIndexOf('}'), $text.LastIndexOf(']'))
    if ($end -lt $start) { return $null }
    return $text.Substring($start, $end - $start + 1) | ConvertFrom-Json
}

# Data object types to capture
$DATA_OBJECT_TYPES = @(
    "Lakehouse",
    "Warehouse",
    "Dataflow",
    "Eventhouse",
    "KQLDatabase",
    "MirroredDatabase",
    "SQLDatabase"
)

# Fabric auto-generates hidden system items (e.g. the staging Lakehouse/Warehouse
# behind Dataflows Gen2) that are not shown in the UI and must not be captured.
# Item names matching any of these patterns are skipped.
$SYSTEM_ITEM_PATTERNS = @(
    '^Staging(Lakehouse|Warehouse)ForDataflows',
    '^DataflowsStaging(Lakehouse|Warehouse)'
)

# Resolve default paths
$deployDir = $PSScriptRoot
$rootDir = Split-Path $deployDir -Parent

if (-not $OutputPath) {
    $OutputPath = Join-Path $deployDir "artifact_mapping.json"
}
if ($UpdateParameterYml -and -not $ParameterYmlPath) {
    $ParameterYmlPath = Join-Path $rootDir "parameter.yml"
}

# --- List workspace items ---
Write-Host "Capturing artifacts from workspace: $WorkspaceName"

[string]$workspacePath = "$WorkspaceName.Workspace"
Write-Host "Running: fab ls $workspacePath -l --output_format json"
$rawOutput = fab ls $workspacePath -l --output_format json
$response = ConvertFrom-FabJson $rawOutput

if (-not $response) {
    throw "Fabric CLI returned no parseable JSON for '$workspacePath'. Raw output: $(($rawOutput -join ' ').Trim())"
}
if ($response.status -ne "Success") {
    throw "Fabric CLI returned status: $($response.status)"
}

$allItems = $response.result.data

# --- Capture workspace ID ---
Write-Host "Capturing workspace ID..."
$rawWs = fab get $workspacePath -q .
$wsJson = ConvertFrom-FabJson $rawWs
if (-not $wsJson) {
    throw "Could not parse workspace metadata for '$workspacePath'. Raw output: $(($rawWs -join ' ').Trim())"
}
$workspaceId = $wsJson.id
Write-Host "  Workspace ID: $workspaceId"

# --- Filter and categorize items ---
$mapping = [ordered]@{
    workspace_name = $WorkspaceName
    workspace_id   = $workspaceId
    items          = [ordered]@{}
    sql_endpoints  = [ordered]@{}
}

foreach ($item in $allItems) {
    $fullName = $item.name
    $itemId = $item.id

    # Parse "name.Type" format — split on last dot
    $lastDot = $fullName.LastIndexOf(".")
    if ($lastDot -gt 0) {
        $itemName = $fullName.Substring(0, $lastDot)
        $itemType = $fullName.Substring($lastDot + 1)
    } else {
        $itemName = $fullName
        $itemType = ""
    }

    # Skip SQLEndpoint items — we get connectionString and id from fab get on the Lakehouse
    if ($itemType -eq "SQLEndpoint") { continue }

    # Skip Fabric-generated system items (e.g. Dataflows Gen2 staging Lakehouse/Warehouse)
    if ($SYSTEM_ITEM_PATTERNS | Where-Object { $itemName -match $_ }) {
        Write-Host "  Skipping system-generated item: $itemName ($itemType)"
        continue
    }

    # Capture data object types
    if ($itemType -in $DATA_OBJECT_TYPES) {
        if (-not $mapping.items.Contains($itemType)) {
            $mapping.items[$itemType] = [ordered]@{}
        }
        $mapping.items[$itemType][$itemName] = [ordered]@{
            id   = $itemId
            type = $itemType
        }
        Write-Host "  Captured ${itemType}: $itemName ($itemId)"

        # Get SQL endpoint properties for Lakehouses
        if ($itemType -eq "Lakehouse") {
            [string]$lhPath = "$WorkspaceName.Workspace/$itemName.Lakehouse"
            $sqlProps = [ordered]@{}
            $maxAttempts = 3

            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                try {
                    $rawLh = fab get $lhPath -q .
                    $lhJson = ConvertFrom-FabJson $rawLh

                    if (-not $lhJson) {
                        $snippet = ($rawLh -join ' ').Trim()
                        if ($snippet.Length -gt 200) { $snippet = $snippet.Substring(0, 200) + '...' }
                        Write-Host "    Attempt ${attempt}/${maxAttempts}: no JSON from 'fab get $lhPath' (raw: $snippet)"
                        Start-Sleep -Seconds 10
                        continue
                    }

                    $sqlEndpointProps = $lhJson.properties.sqlEndpointProperties
                    $rawConnString = $sqlEndpointProps.connectionString
                    $sqlId = $sqlEndpointProps.id

                    if ($rawConnString) {
                        $sqlProps.connectionString = ($rawConnString -replace '^(.+?)(\.datawarehouse)', { $_.Groups[1].Value.ToUpper() + $_.Groups[2].Value })
                    }
                    if ($sqlId) { $sqlProps.id = $sqlId }

                    if ($sqlProps.Count -gt 0) { break }

                    # Item exists but the SQL analytics endpoint hasn't populated yet.
                    Write-Host "    Attempt ${attempt}/${maxAttempts}: SQL endpoint for ${itemName} not populated yet"
                    Start-Sleep -Seconds 10
                } catch {
                    Write-Host "    Attempt ${attempt}/${maxAttempts}: error reading SQL endpoint for ${itemName}: $_"
                    Start-Sleep -Seconds 10
                }
            }

            if ($sqlProps.Count -gt 0) {
                if ($mapping.sql_endpoints.Contains($itemName)) {
                    foreach ($key in $sqlProps.Keys) {
                        $mapping.sql_endpoints[$itemName][$key] = $sqlProps[$key]
                    }
                } else {
                    $mapping.sql_endpoints[$itemName] = $sqlProps
                }
                Write-Host "    SQL Endpoint: $($sqlProps.connectionString)"
            } else {
                Write-Host "    Warning: SQL endpoint for ${itemName} could not be captured (may still be provisioning, or the service principal lacks access)"
            }
        }
    }
}

# --- Write artifact_mapping.json ---
$outputDir = Split-Path $OutputPath -Parent
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$mapping | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host "Artifact mapping written to: $OutputPath"

# --- Optionally update parameter.yml ---
if ($UpdateParameterYml) {
    # Ensure powershell-yaml is available
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        Write-Host "Installing powershell-yaml module..."
        Install-Module powershell-yaml -Force -Scope CurrentUser
    }
    Import-Module powershell-yaml

    # Build parameter.yml from scratch
    $params = [ordered]@{}

    # --- find_replace entries using dynamic fabric-cicd tokens ---
    $findReplaceEntries = @()

    # Workspace ID
    if ($mapping.workspace_id) {
        $findReplaceEntries += [ordered]@{
            find_value    = $mapping.workspace_id
            replace_value = [ordered]@{
                _ALL_ = "`$workspace.`$id"
            }
        }
        Write-Host "  find_replace: $($mapping.workspace_id) -> `$workspace.`$id"
    }

    # Dataflow references in mashup.pq need a regex capture group and a file
    # filter. This follows the fabric-cicd Dataflow guidance and avoids
    # replacing an unrelated occurrence of the same GUID elsewhere in the repo.
    $dataflowFiles = @(Get-ChildItem -Path $rootDir -Recurse -File -Filter "mashup.pq" |
        Where-Object { $_.DirectoryName -match '\.Dataflow$' })

    foreach ($itemType in $mapping.items.Keys) {
        foreach ($itemName in $mapping.items[$itemType].Keys) {
            $info = $mapping.items[$itemType][$itemName]

            if ($itemType -eq "Dataflow") {
                foreach ($dataflowFile in $dataflowFiles) {
                    $relativePath = $dataflowFile.FullName.Substring($rootDir.Length).TrimStart('\', '/') -replace '\\', '/'
                    $relativePath = "/$relativePath"
                    $dataflowLines = Get-Content -Path $dataflowFile.FullName

                    foreach ($line in $dataflowLines) {
                        $idIndex = $line.IndexOf($info.id, [System.StringComparison]::OrdinalIgnoreCase)
                        if ($idIndex -lt 0) { continue }

                        $escapedLine = [regex]::Escape($line)
                        $escapedId = [regex]::Escape($info.id)
                        $escapedIdIndex = $escapedLine.IndexOf($escapedId, [System.StringComparison]::OrdinalIgnoreCase)
                        if ($escapedIdIndex -lt 0) { continue }

                        # Capture only the source Dataflow ID as group 1.
                        $regex = $escapedLine.Substring(0, $escapedIdIndex) +
                            "($escapedId)" +
                            $escapedLine.Substring($escapedIdIndex + $escapedId.Length)

                        $findReplaceEntries += [ordered]@{
                            find_value    = $regex
                            replace_value = [ordered]@{
                                _ALL_ = "`$items.Dataflow.$itemName.`$id"
                            }
                            is_regex      = "true"
                            item_type     = "Dataflow"
                            item_name     = $dataflowFile.Directory.Name.Substring(0, $dataflowFile.Directory.Name.Length - ".Dataflow".Length)
                            file_path     = $relativePath
                        }
                        Write-Host "  find_replace regex: $($info.id) -> `$items.Dataflow.$itemName.`$id ($relativePath)"
                    }
                }
                continue
            }

            $findReplaceEntries += [ordered]@{
                find_value    = $info.id
                replace_value = [ordered]@{
                    _ALL_ = "`$items.$itemType.$itemName.`$id"
                }
            }
            Write-Host "  find_replace: $($info.id) -> `$items.$itemType.$itemName.`$id"

            # Add SQL endpoint entries for Lakehouses
            if ($itemType -eq "Lakehouse") {
                $sqlInfo = $mapping.sql_endpoints[$itemName]
                if ($sqlInfo -and $sqlInfo.id) {
                    $findReplaceEntries += [ordered]@{
                        find_value    = $sqlInfo.id
                        replace_value = [ordered]@{
                            _ALL_ = "`$items.Lakehouse.$itemName.`$sqlendpointid"
                        }
                    }
                    Write-Host "  find_replace: $($sqlInfo.id) -> `$items.Lakehouse.$itemName.`$sqlendpointid"
                }
                if ($sqlInfo -and $sqlInfo.connectionString) {
                    $findReplaceEntries += [ordered]@{
                        find_value    = $sqlInfo.connectionString
                        replace_value = [ordered]@{
                            _ALL_ = "`$items.Lakehouse.$itemName.`$sqlendpoint"
                        }
                    }
                    Write-Host "  find_replace: $($sqlInfo.connectionString) -> `$items.Lakehouse.$itemName.`$sqlendpoint"
                }
            }
        }
    }

    if ($findReplaceEntries.Count -gt 0) {
        $params.find_replace = $findReplaceEntries
    }

    # Write parameter.yml
    $yamlOutput = $params | ConvertTo-Yaml
    $yamlOutput | Set-Content -Path $ParameterYmlPath -Encoding UTF8
    Write-Host "Generated parameter.yml at: $ParameterYmlPath"
    Write-Host ""
    Write-Host "=== parameter.yml contents ==="
    Write-Host $yamlOutput
    Write-Host "=== end parameter.yml ==="
}

Write-Host "Artifact capture completed successfully."
exit 0
