<#
.SYNOPSIS
    Deploys the Azure Logic Apps Notification Routing POC infrastructure and application code.

.DESCRIPTION
    End-to-end deployment script that:
    1. Creates or validates the resource group
    2. Deploys Bicep infrastructure (Application Insights, Logic Apps, and API connections)
    3. Outputs the Orchestrator callback URL for Azure DevOps configuration

.PARAMETER Environment
    Target environment: dev, staging, or prod

.PARAMETER ResourceGroup
    Azure resource group name

.PARAMETER Location
    Azure region (default: eastus)

.PARAMETER AppName
    Short application name prefix for resource naming (default: notifications)

.PARAMETER SubscriptionId
    Azure subscription ID. If provided, sets the active subscription before deploying.

.PARAMETER NotificationFromEmail
    Microsoft 365 mailbox used by Microsoft Graph to send notification emails.

.PARAMETER SharePointServiceAccountEmail
    Account used to authorize the SharePoint API connection.

.PARAMETER SharePointSiteUrl
    SharePoint site hosting routing-rules.json.

.PARAMETER SharePointRulesFilePath
    Site-relative path to routing-rules.json.

.PARAMETER OwnerTech
    Technical owner email. Must be an @aveva.com address.

.PARAMETER OwnerBusiness
    Business owner email. Must be an @aveva.com address.

.PARAMETER Team
    Official team name used for Azure resource tagging.

.EXAMPLE
    .\deploy.ps1 -Environment dev -ResourceGroup rg-notifications-dev -NotificationFromEmail notifications@contoso.com
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [string]$Location = 'west2',

    [string]$AppName = 'notificationspoc',

    [string]$SubscriptionId,

    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$NotificationFromEmail = 'sbodhankar@MngEnvMCAP628198.onmicrosoft.com',

    [ValidatePattern('^https://[^/]+\.sharepoint\.com/sites/[^/]+/?$')]
    [string]$SharePointSiteUrl = 'https://mngenvmcap628198.sharepoint.com/sites/demosite',

    [ValidateNotNullOrEmpty()]
    [string]$SharePointRulesFilePath = '/Shared Documents/routing-rules.json',

    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$SharePointServiceAccountEmail = 'sbodhankar@MngEnvMCAP628198.onmicrosoft.com',

    [Parameter(Mandatory)]
    [ValidatePattern('(?i)^[^@\s]+@aveva\.com$')]
    [string]$OwnerTech,

    [Parameter(Mandatory)]
    [ValidatePattern('(?i)^[^@\s]+@aveva\.com$')]
    [string]$OwnerBusiness,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Team
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step([string]$Message) {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor Cyan
}

function Assert-AzureCli {
    try {
        $null = az version 2>$null
    } catch {
        throw 'Azure CLI is not installed or not on PATH. Install from https://aka.ms/installazurecliwindows'
    }

    $account = az account show --query '{name:name, state:state}' --output json 2>$null | ConvertFrom-Json
    if (-not $account -or $account.state -ne 'Enabled') {
        throw "No active Azure subscription found. Run 'az login' and 'az account set --subscription <id>'"
    }
    Write-Host "  Logged in to subscription: $($account.name)" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Step 0 — Validate prerequisites
# ---------------------------------------------------------------------------
Write-Step 'Step 0 — Validating prerequisites'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot

Assert-AzureCli

if ($SubscriptionId) {
    Write-Host "  Setting subscription to '$SubscriptionId'..." -ForegroundColor White
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription '$SubscriptionId'" }
    Write-Host '  Subscription set.' -ForegroundColor Green
}

$SubscriptionId = az account show --query id --output tsv
if (-not $SubscriptionId) { throw 'Could not determine the active Azure subscription ID.' }

# ---------------------------------------------------------------------------
# Step 1 — Create resource group
# ---------------------------------------------------------------------------
Write-Step 'Step 1 — Ensuring resource group exists'

$createDate = Get-Date -Format 'yyyy.MM.dd'
$resourceTags = @{
    environment   = $Environment
    application   = 'enterprise-notification-routing'
    managedBy     = 'bicep'
    OwnerTech     = $OwnerTech
    OwnerBusiness = $OwnerBusiness
    CreateDate    = $createDate
    team          = $Team
}

$rgExists = az group exists --name $ResourceGroup
if ($rgExists -eq 'false') {
    Write-Host "  Creating resource group '$ResourceGroup' in '$Location'..." -ForegroundColor White
    az group create `
        --name $ResourceGroup `
        --location $Location `
        --tags `
            "environment=$Environment" `
            'application=enterprise-notification-routing' `
            'managedBy=bicep' `
            "OwnerTech=$OwnerTech" `
            "OwnerBusiness=$OwnerBusiness" `
            "CreateDate=$createDate" `
            "team=$Team" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to create resource group '$ResourceGroup'." }
    Write-Host '  Resource group created.' -ForegroundColor Green
} else {
    Write-Host "  Resource group '$ResourceGroup' already exists." -ForegroundColor Green
    Write-Host '  Merging required policy tags into the resource group...' -ForegroundColor White
    $resourceGroupId = az group show --name $ResourceGroup --query id --output tsv
    az tag update `
        --resource-id $resourceGroupId `
        --operation Merge `
        --tags `
            "environment=$Environment" `
            'application=enterprise-notification-routing' `
            'managedBy=bicep' `
            "OwnerTech=$OwnerTech" `
            "OwnerBusiness=$OwnerBusiness" `
            "CreateDate=$createDate" `
            "team=$Team" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to update tags on resource group '$ResourceGroup'." }
}

# ---------------------------------------------------------------------------
# Step 2 — Deploy infrastructure
# ---------------------------------------------------------------------------
Write-Step 'Step 2 — Deploying infrastructure via Bicep'

$deploymentName = "notifications-${Environment}-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

$bicepMain   = Join-Path $projectRoot 'bicep\main.bicep'
$bicepParams = Join-Path $projectRoot "bicep\parameters\main.$Environment.bicepparam"

if (-not (Test-Path $bicepMain)) { throw "Bicep file not found: $bicepMain" }

# Pre-compile Bicep → ARM JSON to avoid the CLI double-compilation streaming bug.
# When az deployment group create receives a .bicep file it compiles it internally
# twice (once for validation, once for submit), which corrupts the HTTP response stream.
$armJsonPath    = Join-Path $env:TEMP "notifications-main-$deploymentName.json"
$armParamsPath  = Join-Path $env:TEMP "notifications-params-$deploymentName.json"

Write-Host "  Compiling Bicep to ARM JSON..." -ForegroundColor White
az bicep build --file $bicepMain --outfile $armJsonPath 2>&1 | Where-Object { $_ -notmatch '^WARNING|^A new Bicep' } | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw 'Bicep compilation failed.' }

# Build parameter JSON from the bicepparam file, then inject runtime values
az bicep build-params --file $bicepParams --outfile $armParamsPath 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    # Fallback: construct parameter JSON inline (bicep build-params not available)
    @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{
            environmentName       = @{ value = $Environment }
            location              = @{ value = $Location }
            appName               = @{ value = $AppName }
            logRetentionDays      = @{ value = 30 }
            notificationFromEmail = @{ value = $NotificationFromEmail }
            adoOrganisationUrl    = @{ value = 'https://dev.azure.com/sbodhankar0209' }
            sharePointServiceAccountEmail = @{ value = $SharePointServiceAccountEmail }
            sharePointSiteUrl     = @{ value = $SharePointSiteUrl }
            sharePointRulesFilePath = @{ value = $SharePointRulesFilePath }
            tags                  = @{ value = $resourceTags }
        }
    } | ConvertTo-Json -Depth 10 | Set-Content $armParamsPath
} else {
    # Inject runtime values into the compiled params JSON
    $p = Get-Content $armParamsPath -Raw | ConvertFrom-Json
    $p.parameters.notificationFromEmail = @{ value = $NotificationFromEmail }
    $p.parameters | Add-Member -MemberType NoteProperty -Name sharePointServiceAccountEmail -Value @{ value = $SharePointServiceAccountEmail } -Force
    $p.parameters | Add-Member -MemberType NoteProperty -Name sharePointSiteUrl -Value @{ value = $SharePointSiteUrl } -Force
    $p.parameters | Add-Member -MemberType NoteProperty -Name sharePointRulesFilePath -Value @{ value = $SharePointRulesFilePath } -Force
    $p.parameters.tags                = @{ value = $resourceTags }
    $p | ConvertTo-Json -Depth 10 | Set-Content $armParamsPath
}

Write-Host "  Submitting deployment '$deploymentName' via ARM REST API..." -ForegroundColor White

# az deployment group create has a streaming-response bug on this CLI version
# that always returns exit 1 ("content already consumed").
# Workaround: submit directly via ARM REST API using PowerShell's HTTP client.
$armToken  = az account get-access-token --subscription $SubscriptionId --query accessToken -o tsv
$armUri    = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Resources/deployments/$deploymentName`?api-version=2021-04-01"
$armBody   = @{
    properties = @{
        mode       = 'Incremental'
        template   = (Get-Content $armJsonPath   -Raw | ConvertFrom-Json)
        parameters = (Get-Content $armParamsPath -Raw | ConvertFrom-Json).parameters
    }
} | ConvertTo-Json -Depth 100

try {
    $submitResult = Invoke-RestMethod -Method PUT -Uri $armUri `
        -Headers @{ Authorization = "Bearer $armToken"; 'Content-Type' = 'application/json' } `
        -Body $armBody -TimeoutSec 60
    Write-Host "  Accepted (state: $($submitResult.properties.provisioningState))" -ForegroundColor Green
} catch {
    Write-Host $_.Exception.Response | ConvertTo-Json -ForegroundColor Red
    throw "Failed to submit deployment via ARM REST API: $_"
}

Write-Host "  Polling for completion (timeout 15 min)..." -ForegroundColor White

$timeout = (Get-Date).AddMinutes(15)
$status  = ''
while ((Get-Date) -lt $timeout) {
    Start-Sleep -Seconds 20
    $status = az deployment group show `
        --name $deploymentName --resource-group $ResourceGroup `
        --query "properties.provisioningState" -o tsv 2>$null
    Write-Host "    $(Get-Date -Format 'HH:mm:ss')  $status" -ForegroundColor DarkGray
    if ($status -in @('Succeeded', 'Failed', 'Canceled')) { break }
}

if ($status -ne 'Succeeded') {
    az deployment group show --name $deploymentName -g $ResourceGroup --query "properties.error" -o json 2>$null | Write-Host
    throw "Deployment ended with status '$status'. Check: https://portal.azure.com/#@/resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/deployments"
}

$deploymentOutput   = az deployment group show `
    --name $deploymentName --resource-group $ResourceGroup `
    --query "properties.outputs" --output json 2>$null | ConvertFrom-Json

Write-Host "  Infrastructure deployed successfully (deployment: $deploymentName)" -ForegroundColor Green

# Clean up temp files
Remove-Item $armJsonPath, $armParamsPath -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Step 3 — Validate deployment
# ---------------------------------------------------------------------------
Write-Step 'Step 3 — Validating deployment'

$orchestratorUrl = $deploymentOutput.orchestratorTriggerEndpoint.value
$testPayload = @{
    id        = [System.Guid]::NewGuid().ToString()
    eventType = 'workitem.updated'
    message   = @{ text = 'Deploy validation ping' }
    resource  = @{
        id           = 99999
        workItemType = 'Bug'
        title        = 'Deployment Validation Test'
        state        = 'Active'
        url          = 'https://dev.azure.com/sbodhankar0209/AgileProject/_apis/wit/workItems/99999'
        fields       = @{
            'System.TeamProject'                     = 'AgileProject2'
            'System.AreaPath'                        = 'AgileProject2'
            'System.WorkItemType'                    = 'Bug'
            'System.State'                           = 'Active'
            'System.Title'                           = 'Deployment Validation Test'
            'Microsoft.VSTS.Common.Priority'         = 4
            'Custom.IMSProduct'                      = 'Unknown'
            'Custom.IMSProductLine'                  = 'Unknown'
            'Custom.IMSCybersecurity'                = $false
            'Custom.IMSHotfix'                       = $false
        }
    }
    resourceContainers = @{
        project = @{ id = 'test-id'; name = 'AgileProject2' }
    }
} | ConvertTo-Json -Depth 10

try {
    $response = Invoke-RestMethod `
        -Method Post `
        -Uri $orchestratorUrl `
        -ContentType 'application/json' `
        -Body $testPayload

    Write-Host "  Validation response: $($response | ConvertTo-Json -Compress)" -ForegroundColor Green
} catch {
    Write-Warning "  Validation ping failed (non-blocking): $_"
    Write-Host "  The orchestrator URL may require a few minutes before becoming available." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Step 'Deployment Complete'

Write-Host "  Environment:           $Environment" -ForegroundColor White
Write-Host "  Resource Group:        $ResourceGroup" -ForegroundColor White
Write-Host "" -ForegroundColor White
Write-Host "  ┌─ Next Steps ─────────────────────────────────────────────┐" -ForegroundColor Cyan
Write-Host "  │" -ForegroundColor Cyan
Write-Host "  │  1. Configure Azure DevOps webhook:" -ForegroundColor Cyan
Write-Host "  │     URL: (see Orchestrator trigger URL in Azure Portal)" -ForegroundColor Cyan
Write-Host "  │     Authentication: signed callback URL" -ForegroundColor Cyan
Write-Host "  │" -ForegroundColor Cyan
Write-Host "  │  2. Authorize the SharePoint and Teams API connections" -ForegroundColor Cyan
Write-Host "  │     in Azure Portal, then test a work-item event" -ForegroundColor Cyan
Write-Host "  │" -ForegroundColor Cyan
Write-Host " │ 3. Ask an Entra administrator to grant Microsoft Graph" -ForegroundColor Cyan
Write-Host " │     Mail.Send to principal: $($deploymentOutput.emailNotifierPrincipalId.value)" -ForegroundColor Cyan
Write-Host " │" -ForegroundColor Cyan
Write-Host " │ 4. Monitor via Application Insights:" -ForegroundColor Cyan
Write-Host "  │     https://portal.azure.com/#resource/subscriptions/.../overview" -ForegroundColor Cyan
Write-Host "  │" -ForegroundColor Cyan
Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
