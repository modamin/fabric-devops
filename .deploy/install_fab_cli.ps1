param(
    [string]$FabricCliVersion = "latest"
)

$ErrorActionPreference = 'Stop'
Write-Host "Installing ms-fabric-cli..."
if ($FabricCliVersion -eq "latest") {
    pip install ms-fabric-cli
} else {
    pip install ms-fabric-cli==$FabricCliVersion
}
if ($LASTEXITCODE -ne 0) { throw "ms-fabric-cli installation failed." }

Write-Host "Configuring Fabric CLI for CI/CD..."
fab config set encryption_fallback_enabled true
if ($LASTEXITCODE -ne 0) { throw "Fabric CLI configuration failed." }

Write-Host "Authenticating with Fabric CLI using federated token..."
$tenantId = $env:tenantId
$clientId = $env:servicePrincipalId
if (-not $tenantId -or -not $clientId) { throw "AzureCLI@2 must expose the service connection identity." }
if ($env:idToken) {
    fab auth login -u $clientId --federated-token $env:idToken --tenant $tenantId
} elseif ($env:servicePrincipalKey) {
    fab auth login -u $clientId -p $env:servicePrincipalKey --tenant $tenantId
} else {
    throw "No federated token or service principal key was supplied by AzureCLI@2."
}
if ($LASTEXITCODE -ne 0) { throw "Fabric CLI authentication failed." }
