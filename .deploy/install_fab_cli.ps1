param(
    [string]$FabricCliVersion = "latest"
)

Write-Host "Installing ms-fabric-cli..."
if ($FabricCliVersion -eq "latest") {
    pip install ms-fabric-cli
} else {
    pip install ms-fabric-cli==$FabricCliVersion
}

Write-Host "Configuring Fabric CLI for CI/CD..."
fab config set encryption_fallback_enabled true

Write-Host "Authenticating with Fabric CLI using federated token..."
$tenantId = az account show --query tenantId -o tsv
$clientId = az account show --query user.name -o tsv
fab auth login -u $clientId --federated-token $env:idToken --tenant $tenantId
