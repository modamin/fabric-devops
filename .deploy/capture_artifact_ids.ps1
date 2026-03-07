<#
.SYNOPSIS
    Capture Fabric artifact IDs from a workspace.

.DESCRIPTION
    Lists workspace items using Fabric CLI and captures metadata for data objects
    (Lakehouse, Warehouse, etc.), including SQL endpoint properties for Lakehouses.
    Optionally updates parameter.yml with dynamic fabric-cicd find_replace tokens.

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

# Data object types to capture
$DATA_OBJECT_TYPES = @(
    "Lakehouse",
    "Warehouse",
    "Eventhouse",
    "KQLDatabase",
    "MirroredDatabase",
    "SQLDatabase"
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
$response = ($rawOutput -join "`n") | ConvertFrom-Json

if ($response.status -ne "Success") {
    throw "Fabric CLI returned status: $($response.status)"
}

$allItems = $response.result.data

# --- Capture workspace ID ---
Write-Host "Capturing workspace ID..."
$rawWs = fab get $workspacePath -q .
$wsJson = ($rawWs -join "`n") | ConvertFrom-Json
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
            try {
                $rawLh = fab get $lhPath -q .
                $lhJson = ($rawLh -join "`n") | ConvertFrom-Json
                $sqlEndpointProps = $lhJson.properties.sqlEndpointProperties
                $rawConnString = $sqlEndpointProps.connectionString
                $connString = ($rawConnString -replace '^(.+?)(\.datawarehouse)', { $_.Groups[1].Value.ToUpper() + $_.Groups[2].Value })
                $sqlId = $sqlEndpointProps.id

                $sqlProps = [ordered]@{}
                if ($connString) { $sqlProps.connectionString = $connString }
                if ($sqlId) { $sqlProps.id = $sqlId }

                if ($sqlProps.Count -gt 0) {
                    if ($mapping.sql_endpoints.Contains($itemName)) {
                        foreach ($key in $sqlProps.Keys) {
                            $mapping.sql_endpoints[$itemName][$key] = $sqlProps[$key]
                        }
                    } else {
                        $mapping.sql_endpoints[$itemName] = $sqlProps
                    }
                    Write-Host "    SQL Endpoint: $connString"
                }
            } catch {
                Write-Host "    Warning: Could not get SQL endpoint for ${itemName}: $_"
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

    foreach ($itemType in $mapping.items.Keys) {
        foreach ($itemName in $mapping.items[$itemType].Keys) {
            $info = $mapping.items[$itemType][$itemName]
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
