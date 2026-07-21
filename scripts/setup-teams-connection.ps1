<#
.SYNOPSIS
    Deploys the new Teams connector Logic App and opens the Azure Portal
    authorization page for the Teams API connection.

.DESCRIPTION
    1. Deploys the Teams connector Logic App (la-notif-teams-dev-connector)
       and the Teams API connection (conn-teams-la-notif-teams-dev) via ARM.
    2. Outputs the Portal URL where sbodhankar@MngEnvMCAP628198.onmicrosoft.com
       must sign in to authorize the connection.

    After authorization, point the dispatcher at the new Logic App to switch
    from the Power Automate webhook approach to the native Teams connector.

.EXAMPLE
    .\scripts\setup-teams-connection.ps1
#>

param(
    [string]$ResourceGroup       = "rg-notifpoc-dev",
    [string]$Location            = "eastus",
    [string]$TeamsNotifierLaName = "la-notif-teams-dev",
    [string]$ServiceAccountEmail = "sbodhankar@MngEnvMCAP628198.onmicrosoft.com"
)

$sub = "852f8491-61e9-4d75-b79a-9744a28c42a5"
$connectorLaName  = "$TeamsNotifierLaName-connector"
$connectionName   = "conn-teams-$TeamsNotifierLaName"
$managedApiId     = "/subscriptions/$sub/providers/Microsoft.Web/locations/$Location/managedApis/teams"

Write-Host "`n=== Step 1: Ensure Teams API connection exists ===" -ForegroundColor Cyan
$tok = (az account get-access-token --subscription $sub --query accessToken -o tsv)
$connUrl = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Web/connections/$connectionName`?api-version=2016-06-01"

$connBody = @{
    location   = $Location
    properties = @{
        displayName = $ServiceAccountEmail
        api         = @{ id = $managedApiId }
    }
} | ConvertTo-Json -Depth 10

Write-Host "  Creating/updating connection: $connectionName"
$conn = Invoke-RestMethod -Method PUT -Uri $connUrl `
    -Headers @{ Authorization = "Bearer $tok"; "Content-Type" = "application/json" } `
    -Body $connBody
Write-Host "  Connection status: $($conn.properties.statuses[0].status)" -ForegroundColor Yellow

Write-Host "`n=== Step 2: Deploy Teams connector Logic App ===" -ForegroundColor Cyan
$laUrl = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$connectorLaName`?api-version=2019-05-01"

$definition = Get-Content "$PSScriptRoot\..\logic-apps\teams-notifier-connector.json" -Raw | ConvertFrom-Json

$laBody = @{
    location   = $Location
    identity   = @{ type = "SystemAssigned" }
    properties = @{
        state      = "Enabled"
        definition = $definition
        parameters = @{
            '$connections' = @{
                value = @{
                    teams = @{
                        connectionId   = $conn.id
                        connectionName = $connectionName
                        id             = $managedApiId
                    }
                }
            }
        }
    }
} | ConvertTo-Json -Depth 20

Write-Host "  Deploying: $connectorLaName"
$la = Invoke-RestMethod -Method PUT -Uri $laUrl `
    -Headers @{ Authorization = "Bearer $tok"; "Content-Type" = "application/json" } `
    -Body $laBody
Write-Host "  Provisioning: $($la.properties.provisioningState)" -ForegroundColor Yellow

# Poll until not Running
$attempts = 0
do {
    Start-Sleep 5
    $la = Invoke-RestMethod -Uri $laUrl -Headers @{ Authorization = "Bearer $tok" }
    Write-Host "  ... $($la.properties.provisioningState)"
    $attempts++
} while ($la.properties.provisioningState -eq 'Updating' -and $attempts -lt 12)

$color = if ($la.properties.provisioningState -eq 'Succeeded') { 'Green' } else { 'Red' }
Write-Host "  Final state: $($la.properties.provisioningState)" -ForegroundColor $color

Write-Host "`n=== Step 3: Authorize the Teams connection ===" -ForegroundColor Cyan
$portalUrl = "https://portal.azure.com/#resource/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Web/connections/$connectionName/edit"
Write-Host ""
Write-Host "  Open this URL in a browser and sign in as:" -ForegroundColor White
Write-Host "  $ServiceAccountEmail" -ForegroundColor Yellow
Write-Host ""
Write-Host "  $portalUrl" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Steps in the Portal:" -ForegroundColor White
Write-Host "  1. Click 'Authorize' on the connection page"
Write-Host "  2. Sign in with $ServiceAccountEmail"
Write-Host "  3. Click Save"
Write-Host ""

# Get the new Logic App's trigger URL
Write-Host "=== Step 4: New Logic App trigger URL ===" -ForegroundColor Cyan
try {
    $cbUrl = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$connectorLaName/triggers/Receive_Teams_Notification_Request/listCallbackUrl?api-version=2019-05-01"
    $cb = Invoke-RestMethod -Method POST -Uri $cbUrl -Headers @{ Authorization = "Bearer $tok" }
    Write-Host "  Connector LA URL: $($cb.value)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  To SWITCH the dispatcher to use this Logic App, update the" -ForegroundColor White
    Write-Host "  'teamsNotifierUrl' parameter on la-notif-dispatcher-dev to:" -ForegroundColor White
    Write-Host "  $($cb.value)" -ForegroundColor Green
} catch {
    Write-Host "  Could not retrieve trigger URL (LA may still be provisioning). Run again after authorization." -ForegroundColor Yellow
}

Write-Host "`nDone. Authorize the connection, then run test-e2e.ps1 to verify." -ForegroundColor Green
