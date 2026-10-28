param(
    [Parameter(Mandatory)][ValidateSet('data', 'bi')][string]$Role,
    [Parameter(Mandatory)][ValidateSet('UAT', 'PROD')][string]$Environment,
    [Parameter(Mandatory)][ValidateSet('selective', 'full')][string]$Mode,
    [Parameter(Mandatory)][string]$DeployConfig,
    [string]$InitializeData = 'False',
    [string]$NotebookName,
    [string]$UseDataArtifact = 'False',
    [string]$RefreshSemanticModels = 'False'
)

$ErrorActionPreference = 'Stop'
$root = Join-Path $env:BUILD_SOURCESDIRECTORY "workspaces/$Role"
$output = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY $Role
New-Item -ItemType Directory -Path $output -Force | Out-Null

& "$PSScriptRoot/install_fab_cli.ps1"
if ($LASTEXITCODE -ne 0) { throw "Fabric CLI setup failed." }

function Capture-Workspace {
    param([string]$Name, [string]$Id, [string]$Path, [switch]$GenerateParameters)
    & "$PSScriptRoot/capture_artifact_ids.ps1" -WorkspaceName $Name -ExpectedWorkspaceId $Id `
        -OutputPath $Path -RepositoryDirectory $root -UpdateParameterYml:$GenerateParameters `
        -ParameterYmlPath (Join-Path $root 'parameter.yml')
    if ($LASTEXITCODE -ne 0) { throw "Workspace capture failed: $Name" }
}

function Publish-Workspace {
    param([string[]]$Types)
    $targetId = if ($Role -eq 'data') { $env:TARGET_DATA_WORKSPACE_ID } else { $env:TARGET_BI_WORKSPACE_ID }
    $arguments = @("$PSScriptRoot/deploy_fabric.py", '--workspace-id', $targetId,
        '--environment', $Environment, '--repository-directory', $root, '--workspace-role', $Role)
    if ($Mode -eq 'selective') { $arguments += @('--deploy-config', $DeployConfig) }
    if ($Types) { $arguments += @('--items') + $Types }
    python @arguments
    if ($LASTEXITCODE -ne 0) { throw "$Role deployment failed." }
}

if ($Role -eq 'data') {
    Capture-Workspace $env:SOURCE_DATA_WORKSPACE_NAME $env:SOURCE_DATA_WORKSPACE_ID `
        (Join-Path $output 'source_data.json') -GenerateParameters
    # Verify the name/ID pair before notebook execution or any deployment.
    Capture-Workspace $env:TARGET_DATA_WORKSPACE_NAME $env:TARGET_DATA_WORKSPACE_ID `
        (Join-Path $output 'target_data.json')
    Publish-Workspace
    if ([bool]::Parse($InitializeData)) {
        & "$PSScriptRoot/run_notebook.ps1" -WorkspaceName $env:TARGET_DATA_WORKSPACE_NAME -NotebookName $NotebookName
        if ($LASTEXITCODE -ne 0) { throw "Data initialization failed." }
    }
    Capture-Workspace $env:TARGET_DATA_WORKSPACE_NAME $env:TARGET_DATA_WORKSPACE_ID `
        (Join-Path $output 'target_data.json')
} else {
    if ([bool]::Parse($UseDataArtifact)) {
        $artifact = Join-Path $env:PIPELINE_WORKSPACE 'data_metadata'
        Copy-Item -LiteralPath (Join-Path $artifact 'source_data.json') -Destination $output
        Copy-Item -LiteralPath (Join-Path $artifact 'target_data.json') -Destination $output
    } else {
        Capture-Workspace $env:SOURCE_DATA_WORKSPACE_NAME $env:SOURCE_DATA_WORKSPACE_ID (Join-Path $output 'source_data.json')
        Capture-Workspace $env:TARGET_DATA_WORKSPACE_NAME $env:TARGET_DATA_WORKSPACE_ID (Join-Path $output 'target_data.json')
    }
    Capture-Workspace $env:SOURCE_BI_WORKSPACE_NAME $env:SOURCE_BI_WORKSPACE_ID (Join-Path $output 'source_bi.json')
    Capture-Workspace $env:TARGET_BI_WORKSPACE_NAME $env:TARGET_BI_WORKSPACE_ID (Join-Path $output 'target_bi.json')
    $arguments = @("$PSScriptRoot/prepare_bi_deployment.py", '--repository-directory', $root,
        '--source-data', (Join-Path $output 'source_data.json'), '--target-data', (Join-Path $output 'target_data.json'),
        '--source-bi', (Join-Path $output 'source_bi.json'), '--target-bi', (Join-Path $output 'target_bi.json'),
        '--environment', $Environment, '--output-directory', $output)
    if ($Mode -eq 'selective') { $arguments += @('--deploy-config', $DeployConfig) }
    python @arguments
    if ($LASTEXITCODE -ne 0) { throw "BI dependency validation failed." }

    & "$PSScriptRoot/create_sm_connections_stage.ps1" -BiWorkspaceId $env:TARGET_BI_WORKSPACE_ID `
        -ConnectionMappingPath (Join-Path $output 'selected_connections.yml') -Environment $Environment `
        -GroupId $env:CONNECTION_GROUP_ID -UserIds $env:CONNECTION_USER_IDS -ParameterYmlPath (Join-Path $root 'parameter.yml')
    $manifest = Get-Content -LiteralPath (Join-Path $output 'bi_dependencies.json') -Raw | ConvertFrom-Json
    if ($manifest.models.Count -gt 0) { Publish-Workspace -Types @('SemanticModel') }
    if ($manifest.reports.Count -gt 0) { Publish-Workspace -Types @('Report') }
    $validationArguments = @("$PSScriptRoot/validate_bi_deployment.py",
        '--manifest', (Join-Path $output 'bi_dependencies.json'),
        '--parameters', (Join-Path $root 'parameter.yml'))
    if ([bool]::Parse($RefreshSemanticModels)) {
        $validationArguments += '--refresh'
    } else {
        Write-Host "Semantic model refresh skipped (refreshSemanticModels is disabled)."
    }
    python @validationArguments
    if ($LASTEXITCODE -ne 0) { throw "BI post-deployment validation or semantic model refresh failed." }
}
Copy-Item -LiteralPath (Join-Path $root 'parameter.yml') -Destination $output
