<#
.SYNOPSIS
    Create semantic model connections and update parameter.yml with bindings.

.DESCRIPTION
    Reads a JSON mapping file to create Fabric SQL connections for semantic models,
    using SQL endpoint details from the target workspace. Appends semantic_model_binding
    entries to an existing parameter.yml file.

.PARAMETER TargetWorkspaceName
    Fabric workspace name to query SQL endpoints from (e.g., UAT or PROD workspace).

.PARAMETER ConnectionMappingPath
    Path to a JSON file mapping connections to semantic models and lakehouses.

.PARAMETER GroupId
    AAD Group ID to grant Owner access on created connections.

.PARAMETER UserIds
    Comma-separated list of AAD User Object IDs to grant Owner access on created connections.

.PARAMETER ParameterYmlPath
    Path to parameter.yml to update with semantic_model_binding entries.

.EXAMPLE
    .\create_sm_connections_stage.ps1 -TargetWorkspaceName "cicd-conn-mgmt-uat" `
        -ConnectionMappingPath ".\connection_mapping.json" `
        -GroupId "bd9da7e3-1acd-476b-9159-3674a310f890" `
        -UserIds "user-object-id-1,user-object-id-2" `
        -ParameterYmlPath ".\parameter.yml"
#>

param(
    [Parameter(Mandatory)][string]$TargetWorkspaceName,
    [Parameter(Mandatory)][string]$ConnectionMappingPath,
    [string]$GroupId,
    [string]$UserIds,
    [Parameter(Mandatory)][string]$ParameterYmlPath
)

$ErrorActionPreference = 'Stop'

# Dot-source reusable connection functions
. "$PSScriptRoot/create_sm_connection.ps1"

# Ensure powershell-yaml is available
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host "Installing powershell-yaml module..."
    Install-Module powershell-yaml -Force -Scope CurrentUser
}
Import-Module powershell-yaml

# --- Read connection mapping ---
Write-Host "=== Creating connections from mapping file: $ConnectionMappingPath ==="
$connectionMapping = Get-Content $ConnectionMappingPath -Raw | ConvertFrom-Json

$semanticModelBindings = @()

foreach ($entry in $connectionMapping) {
    $connName = $entry.connection_name
    $smName = $entry.semantic_model_name
    $lhName = $entry.lakehouse_name

    Write-Host ""
    Write-Host "--- Processing connection: $connName (lakehouse: $lhName) ---"

    # Get SQL endpoint for the lakehouse from target workspace
    $endpoint = Get-LakehouseSqlEndpoint -WorkspaceName $TargetWorkspaceName -LakehouseName $lhName

    # Create or retrieve the connection
    $connectionId = New-FabricConnection -ConnectionName $connName -SqlServer $endpoint.Server -SqlDatabase $endpoint.Database

    # Grant access to group if GroupId provided
    if ($GroupId) {
        Grant-FabricConnectionAccess -ConnectionId $connectionId -PrincipalId $GroupId -PrincipalType 'Group'
    }

    # Grant access to individual users if UserIds provided
    if ($UserIds) {
        $userIdList = $UserIds -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        foreach ($userId in $userIdList) {
            Grant-FabricConnectionAccess -ConnectionId $connectionId -PrincipalId $userId -PrincipalType 'User'
        }
    }

    # Build semantic_model_binding entry
    $bindingEntry = [ordered]@{
        connection_id       = $connectionId
        semantic_model_name = $smName
    }
    $semanticModelBindings += $bindingEntry
    Write-Host "  Binding: connection $connectionId -> semantic model $smName"
}

Write-Host ""
Write-Host "=== All connections created ==="

# --- Update parameter.yml with semantic_model_binding ---
Write-Host ""
Write-Host "Updating parameter.yml with semantic_model_binding entries..."

if (Test-Path $ParameterYmlPath) {
    $existingYaml = Get-Content $ParameterYmlPath -Raw
    $params = $existingYaml | ConvertFrom-Yaml -Ordered
} else {
    Write-Host "  parameter.yml not found — creating from scratch"
    $params = $null
}

if (-not $params) {
    $params = [ordered]@{}
}

if ($semanticModelBindings.Count -gt 0) {
    $params.semantic_model_binding = $semanticModelBindings
    foreach ($binding in $semanticModelBindings) {
        Write-Host "  semantic_model_binding: $($binding.connection_id) -> $($binding.semantic_model_name)"
    }
}

$yamlOutput = $params | ConvertTo-Yaml
$yamlOutput | Set-Content -Path $ParameterYmlPath -Encoding UTF8
Write-Host "Updated parameter.yml at: $ParameterYmlPath"
Write-Host ""
Write-Host "=== parameter.yml contents ==="
Write-Host $yamlOutput
Write-Host "=== end parameter.yml ==="
