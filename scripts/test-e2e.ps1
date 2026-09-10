<#
.SYNOPSIS
    Sends the sample Azure DevOps event to the deployed Orchestrator.

.EXAMPLE
    .\scripts\test-e2e.ps1 -ResourceGroup rg-notifications-dev -Environment dev
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment = 'dev',

    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to select subscription '$SubscriptionId'."
    }
}

$SubscriptionId = az account show --query id --output tsv
if (-not $SubscriptionId) {
    throw "No active Azure subscription. Run 'az login' first."
}

$logicAppName = "la-notif-orchestrator-$Environment"
$triggerName = 'Receive_WorkItem_Webhook'
$callbackUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$logicAppName/triggers/$triggerName/listCallbackUrl?api-version=2019-05-01"
$callbackUrl = az rest --method post --uri $callbackUri --query value --output tsv
if (-not $callbackUrl) {
    throw "Could not retrieve the callback URL for '$logicAppName'."
}

$samplePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\samples\ado-webhook-sample.json'
$payload = Get-Content $samplePath -Raw
$response = Invoke-RestMethod -Method Post -Uri $callbackUrl -ContentType 'application/json' -Body $payload

Write-Host "Orchestrator accepted the test event." -ForegroundColor Green
Write-Host "Correlation ID: $($response.correlationId)"
Write-Host "Check the Orchestrator, Dispatcher, and Teams connector run histories for final delivery."
