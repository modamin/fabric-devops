<#
.SYNOPSIS
    Create OneLake semantic model connections using workspace identity, without SSO.
.DESCRIPTION
    Dot-source this script to import the Fabric REST connection helpers.
    WorkspaceIdentity credentials use the consuming semantic model's workspace identity.
#>

function Invoke-FabricConnectionApi {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('Get', 'Post', 'Patch')][string]$Method = 'Get',
        [hashtable]$Body
    )

    if (-not $Uri.StartsWith('https://api.fabric.microsoft.com/v1/')) {
        throw "Unexpected Fabric API URL: $Uri"
    }
    $token = az account get-access-token --resource 'https://api.fabric.microsoft.com' --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Failed to acquire a Fabric API token.' }
    $arguments = @{
        Uri = $Uri
        Method = $Method
        Headers = @{ Authorization = "Bearer $token" }
        ErrorAction = 'Stop'
    }
    if ($Body) {
        $arguments.ContentType = 'application/json'
        $arguments.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    try {
        Invoke-RestMethod @arguments
    } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        throw "Fabric API $Method $Uri failed: $($_.ErrorDetails.Message)"
    }
}

function Get-FabricConnectionApiItems {
    param([Parameter(Mandatory)][string]$Uri)

    do {
        $page = Invoke-FabricConnectionApi -Uri $Uri
        if ($null -eq $page.value) { throw "Fabric list response is missing 'value': $Uri" }
        $page.value
        $Uri = $page.continuationUri
    } while ($Uri)
}

function Assert-FabricOneLakeConnection {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$OneLakeUrl
    )

    if ($Connection.connectivityType -ne 'ShareableCloud' -or
        $Connection.connectionDetails.type -ne 'AzureDataLakeStorage' -or
        ([string]$Connection.connectionDetails.path).TrimEnd('/') -ine $OneLakeUrl.TrimEnd('/') -or
        $Connection.credentialDetails.credentialType -ne 'WorkspaceIdentity' -or
        $Connection.credentialDetails.singleSignOnType -ne 'None') {
        throw "Connection '$($Connection.displayName)' must be a shareable OneLake connection to '$OneLakeUrl', with WorkspaceIdentity authentication and SSO disabled. Correct it explicitly or use a different connection name."
    }
    if (-not $Connection.id) { throw 'Fabric connection response is missing its ID.' }
}

function New-FabricConnection {
    param(
        [Parameter(Mandatory)][string]$ConnectionName,
        [Parameter(Mandatory)][string]$OneLakeUrl
    )

    if ($OneLakeUrl -notmatch '^https://onelake\.dfs\.fabric\.microsoft\.com/[0-9a-f-]{36}/[0-9a-f-]{36}/?$') {
        throw "Expected a workspace/lakehouse GUID-based OneLake URL, got '$OneLakeUrl'."
    }
    $base = 'https://api.fabric.microsoft.com/v1'
    Write-Host "Checking for existing OneLake connection '$ConnectionName'..."
    $existing = @(Get-FabricConnectionApiItems -Uri "$base/connections" |
        Where-Object displayName -eq $ConnectionName)
    if ($existing.Count -gt 1) { throw "Ambiguous connection name '$ConnectionName'." }
    if ($existing.Count -eq 1) {
        $connection = Invoke-FabricConnectionApi -Uri "$base/connections/$($existing[0].id)"
        Assert-FabricOneLakeConnection -Connection $connection -OneLakeUrl $OneLakeUrl
        Write-Host "Reusing OneLake connection: $($connection.id)"
        return $connection.id
    }

    $types = @(Get-FabricConnectionApiItems -Uri "$base/connections/supportedConnectionTypes?showAllCreationMethods=true" |
        Where-Object type -eq 'AzureDataLakeStorage')
    if ($types.Count -ne 1 -or 'WorkspaceIdentity' -notin $types[0].supportedCredentialTypes) {
        throw 'Fabric does not advertise AzureDataLakeStorage connections with WorkspaceIdentity authentication for this caller.'
    }
    $methods = @($types[0].creationMethods | Where-Object {
        $serverParameter = @($_.parameters | Where-Object { $_.name -eq 'server' -and $_.dataType -eq 'Text' })
        $pathParameter = @($_.parameters | Where-Object { $_.name -eq 'path' -and $_.dataType -eq 'Text' })
        $otherRequired = @($_.parameters | Where-Object { $_.required -and $_.name -notin @('server', 'path') })
        $serverParameter.Count -eq 1 -and $pathParameter.Count -eq 1 -and $otherRequired.Count -eq 0
    })
    if ($methods.Count -ne 1) {
        $metadata = $types[0].creationMethods | ConvertTo-Json -Depth 10 -Compress
        throw "Fabric did not return an unambiguous AzureDataLakeStorage creation method with text server/path parameters. Returned creation methods: $metadata"
    }

    $sourceUri = [uri]$OneLakeUrl
    $body = @{
        connectivityType = 'ShareableCloud'
        displayName = $ConnectionName
        privacyLevel = 'Organizational'
        connectionDetails = @{
            type = 'AzureDataLakeStorage'
            creationMethod = $methods[0].name
            parameters = @(
                @{ dataType = 'Text'; name = 'server'; value = $sourceUri.GetLeftPart([System.UriPartial]::Authority) }
                @{ dataType = 'Text'; name = 'path'; value = $sourceUri.AbsolutePath.TrimStart('/') }
            )
        }
        credentialDetails = @{
            credentials = @{ credentialType = 'WorkspaceIdentity' }
            singleSignOnType = 'None'
            skipTestConnection = ($types[0].supportsSkipTestConnection -eq $true)
        }
    }
    Write-Host "Creating OneLake connection '$ConnectionName' (WorkspaceIdentity, SSO disabled)..."
    $created = Invoke-FabricConnectionApi -Uri "$base/connections" -Method Post -Body $body
    if (-not $created.id) { throw "Created connection '$ConnectionName' did not return an ID." }
    $connection = Invoke-FabricConnectionApi -Uri "$base/connections/$($created.id)"
    Assert-FabricOneLakeConnection -Connection $connection -OneLakeUrl $OneLakeUrl
    return $connection.id
}

function Grant-FabricConnectionAccess {
    param(
        [Parameter(Mandatory)][string]$ConnectionId,
        [Parameter(Mandatory)][string]$PrincipalId,
        [ValidateSet('Group', 'User')][string]$PrincipalType = 'Group'
    )

    Write-Host "Granting Owner access to connection $ConnectionId for $PrincipalType $PrincipalId..."
    $uri = "https://api.fabric.microsoft.com/v1/connections/$ConnectionId/roleAssignments"
    $existing = @(Get-FabricConnectionApiItems -Uri $uri |
        Where-Object { $_.principal.id -eq $PrincipalId })
    if ($existing.Count -gt 1) { throw "Ambiguous connection role for $PrincipalId." }
    if ($existing.Count -eq 1) {
        if ($existing[0].role -eq 'Owner') { return }
        Invoke-FabricConnectionApi -Uri "$uri/$($existing[0].id)" -Method Patch -Body @{ role = 'Owner' } | Out-Null
        return
    }
    Invoke-FabricConnectionApi -Uri $uri -Method Post -Body @{
        principal = @{ id = $PrincipalId; type = $PrincipalType }
        role = 'Owner'
    } | Out-Null
}
