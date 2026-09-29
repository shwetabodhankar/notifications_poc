<#
.SYNOPSIS
    Grants Microsoft Graph Mail.Send to the Email Logic App managed identity.

.DESCRIPTION
    Run this script as an Entra administrator after deploying the Logic App.
    Mail.Send application permission is tenant-wide unless Exchange Online
    application RBAC restricts the identity to the configured sender mailbox.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [string]$LogicAppName = 'la-notif-email-dev'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) {
    throw "Failed to select subscription '$SubscriptionId'."
}

$principalId = az resource show `
    --resource-group $ResourceGroup `
    --resource-type Microsoft.Logic/workflows `
    --name $LogicAppName `
    --query identity.principalId `
    --output tsv
if (-not $principalId) {
    throw "Logic App '$LogicAppName' does not have a system-assigned managed identity."
}

$graphServicePrincipal = az ad sp show `
    --id '00000003-0000-0000-c000-000000000000' `
    --output json | ConvertFrom-Json
$mailSendRole = $graphServicePrincipal.appRoles |
    Where-Object { $_.value -eq 'Mail.Send' -and $_.allowedMemberTypes -contains 'Application' }
if (-not $mailSendRole) {
    throw 'Could not resolve the Microsoft Graph Mail.Send application role.'
}

$assignmentUri = "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments"
$existing = az rest `
    --method get `
    --uri "$assignmentUri`?`$filter=resourceId eq $($graphServicePrincipal.id)" `
    --query "value[?appRoleId=='$($mailSendRole.id)'].id | [0]" `
    --output tsv
if ($existing) {
    Write-Host "Mail.Send is already assigned to '$LogicAppName'." -ForegroundColor Green
    return
}

$token = az account get-access-token `
    --resource-type ms-graph `
    --query accessToken `
    --output tsv
$headers = @{
    Authorization = "Bearer $token"
    'Content-Type' = 'application/json'
}
$body = @{
    principalId = $principalId
    resourceId  = $graphServicePrincipal.id
    appRoleId   = $mailSendRole.id
} | ConvertTo-Json -Compress

$assignment = Invoke-RestMethod `
    -Method Post `
    -Uri $assignmentUri `
    -Headers $headers `
    -Body $body

Write-Host "Granted Mail.Send to '$LogicAppName' (assignment $($assignment.id))." -ForegroundColor Green
Write-Warning 'Restrict this identity to the notification mailbox with Exchange Online application RBAC.'
