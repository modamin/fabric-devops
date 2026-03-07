<#
.SYNOPSIS
    Run a Fabric notebook on demand and wait for completion.

.DESCRIPTION
    Resolves the notebook ID from the workspace, triggers an on-demand run via the
    Fabric REST API, and polls the Location header URL until the job completes or fails.
    Uses the Azure CLI session (from the service connection) to acquire a bearer token.

.PARAMETER WorkspaceName
    Fabric workspace name containing the notebook.

.PARAMETER NotebookName
    Display name of the notebook to run.

.PARAMETER PollIntervalSeconds
    Seconds between status polls. Default 30.

.PARAMETER TimeoutMinutes
    Maximum minutes to wait for completion. Default 60.

.EXAMPLE
    .\run_notebook.ps1 -WorkspaceName "cicd-conn-mgmt-uat" -NotebookName "conn_mgmt_nb"
#>

param(
    [Parameter(Mandatory)][string]$WorkspaceName,
    [Parameter(Mandatory)][string]$NotebookName,
    [int]$PollIntervalSeconds = 30,
    [int]$TimeoutMinutes = 60
)

$ErrorActionPreference = 'Stop'

$fabricApiBase = "https://api.fabric.microsoft.com/v1"

# --- Get bearer token from Azure CLI session ---
Write-Host "Acquiring bearer token from Azure CLI..."
$accessToken = az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv
if (-not $accessToken) {
    throw "Failed to acquire access token from Azure CLI. Ensure the task runs inside AzureCLI@2."
}
$headers = @{ "Authorization" = "Bearer $accessToken" }
Write-Host "  Token acquired."

# --- Resolve IDs ---
Write-Host "=== Running notebook: $NotebookName in workspace: $WorkspaceName ==="

Write-Host "Resolving workspace ID..."
[string]$workspacePath = "$WorkspaceName.Workspace"
$workspaceId = fab get $workspacePath -q 'id'
Write-Host "  Workspace ID: $workspaceId"

Write-Host "Resolving notebook ID..."
[string]$notebookPath = "$WorkspaceName.Workspace/$NotebookName.Notebook"
$notebookId = fab get $notebookPath -q 'id'
Write-Host "  Notebook ID: $notebookId"

# --- Trigger notebook run ---
$runUrl = "$fabricApiBase/workspaces/$workspaceId/items/$notebookId/jobs/instances?jobType=RunNotebook"
Write-Host ""
Write-Host "Triggering notebook run..."
Write-Host "  POST $runUrl"

$response = Invoke-WebRequest -Uri $runUrl -Method Post -Headers $headers -ContentType "application/json"
Write-Host "  Status: $($response.StatusCode)"

# Extract Location header for polling
$locationUrl = $response.Headers["Location"]
if ($locationUrl -is [array]) { $locationUrl = $locationUrl[0] }

if (-not $locationUrl) {
    throw "No Location header in 202 response. Cannot poll for job status."
}

Write-Host "  Location: $locationUrl"

# --- Poll for completion ---
Write-Host ""
Write-Host "Polling for notebook completion (interval: ${PollIntervalSeconds}s, timeout: ${TimeoutMinutes}m)..."

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$finalStatus = $null

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $PollIntervalSeconds

    $statusJson = Invoke-RestMethod -Uri $locationUrl -Method Get -Headers $headers
    $currentStatus = $statusJson.status
    Write-Host "  Status: $currentStatus"

    if ($currentStatus -in @("Completed", "Failed", "Cancelled", "Deduped")) {
        $finalStatus = $currentStatus
        break
    }
}

if (-not $finalStatus) {
    throw "Notebook run timed out after $TimeoutMinutes minutes."
}

Write-Host ""
if ($finalStatus -eq "Completed") {
    Write-Host "Notebook run completed successfully."
} else {
    throw "Notebook run finished with status: $finalStatus"
}
