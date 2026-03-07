<#
.SYNOPSIS
    Reusable functions for creating and managing Fabric Semantic Model connections.

.DESCRIPTION
    Provides functions to query lakehouse SQL endpoints, create Fabric connections,
    and grant role access. Dot-source this script to import the functions.

.EXAMPLE
    . "$PSScriptRoot/create_sm_connection.ps1"
    $endpoint = Get-LakehouseSqlEndpoint -WorkspaceName "my-ws" -LakehouseName "my-lh"
    $connId = New-FabricConnection -ConnectionName "my-conn" -SqlServer $endpoint.Server -SqlDatabase $endpoint.Database
    Grant-FabricConnectionAccess -ConnectionId $connId -GroupId "aad-group-id"
#>

function Get-LakehouseSqlEndpoint {
    <#
    .SYNOPSIS
        Query SQL endpoint properties for a lakehouse.
    .OUTPUTS
        Hashtable with Server and Database keys.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkspaceName,
        [Parameter(Mandatory)][string]$LakehouseName
    )

    Write-Host "Querying SQL endpoint for $LakehouseName in workspace $WorkspaceName..."
    [string]$lakehousePath = "$WorkspaceName.Workspace/$LakehouseName.Lakehouse"

    $server = fab get $lakehousePath -q 'properties.sqlEndpointProperties.connectionString'
    $database = fab get $lakehousePath -q 'properties.sqlEndpointProperties.id'

    Write-Host "SQL Server: $server"
    Write-Host "SQL Database: $database"

    return @{
        Server   = $server
        Database = $database
    }
}

function New-FabricConnection {
    <#
    .SYNOPSIS
        Create or retrieve a Fabric SQL connection.
    .OUTPUTS
        Connection ID (string).
    #>
    param(
        [Parameter(Mandatory)][string]$ConnectionName,
        [Parameter(Mandatory)][string]$SqlServer,
        [Parameter(Mandatory)][string]$SqlDatabase
    )

    [string]$connectionPath = ".connections/$ConnectionName.Connection"
    Write-Host "Checking for existing connection '$ConnectionName'..."
    $connectionExists = (fab exists $connectionPath) -join ""
    Write-Host "Connection exists: $connectionExists"

    if ($connectionExists -eq "true") {
        Write-Host "Connection '$ConnectionName' already exists."
        $connectionId = fab get $connectionPath -q 'id'
        Write-Host "Connection ID: $connectionId"
        return $connectionId
    }

    Write-Host "Creating connection '$ConnectionName'..."
    $params = @(
        "connectionDetails.type=SQL",
        "connectionDetails.parameters.server=$SqlServer",
        "connectionDetails.parameters.database=$SqlDatabase",
        "credentialDetails.type=ServicePrincipal",
        "credentialDetails.tenantId=$env:FAB_TENANT_ID",
        "credentialDetails.servicePrincipalClientId=$env:FAB_CLIENT_ID",
        "credentialDetails.servicePrincipalSecret=$env:FAB_CLIENT_SECRET",
        "credentialDetails.singleSignOnType=None",
        "credentialDetails.skipTestConnection=False"
    ) -join ","

    fab create $connectionPath -P $params | Out-Null

    Write-Host "Retrieving connection ID..."
    $connectionId = fab get $connectionPath -q 'id'
    Write-Host "Connection ID: $connectionId"

    return $connectionId
}

function Grant-FabricConnectionAccess {
    <#
    .SYNOPSIS
        Grant Owner role on a connection to an AAD principal (Group or User).
    .PARAMETER PrincipalType
        Type of principal: 'Group' or 'User'. Defaults to 'Group'.
    #>
    param(
        [Parameter(Mandatory)][string]$ConnectionId,
        [Parameter(Mandatory)][string]$PrincipalId,
        [ValidateSet('Group', 'User')][string]$PrincipalType = 'Group'
    )

    Write-Host "Granting access to connection $ConnectionId for $PrincipalType $PrincipalId..."
    $apiUrl = "connections/$ConnectionId/roleAssignments"
    $payload = '{"principal":{"id":"' + $PrincipalId + '","type":"' + $PrincipalType + '"},"role":"Owner"}'
    Write-Host "API URL: $apiUrl"
    Write-Host "Payload: $payload"
    fab api -X post $apiUrl -H "Content-Type=application/json" -i $payload | Out-Null
}
