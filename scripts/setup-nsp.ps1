<#
.SYNOPSIS
    Creates (or idempotently updates) an Azure Network Security Perimeter that
    allows the current caller's IP and all resources in the subscription to
    reach the storage account — even when the subscription policy forces
    publicNetworkAccess = Disabled.

.PARAMETER ResourceGroup
    Resource group containing the storage account.

.PARAMETER StorageAccountName
    Name of the storage account to associate with the NSP.

.PARAMETER SubscriptionId
    Azure subscription ID that hosts the storage account.
    Defaults to the currently active subscription.

.PARAMETER NspName
    Name of the NSP resource to create/reuse.  Default: nsp-<storageAccountName>

.PARAMETER CallerIp
    Public IP of the machine running this script.  If omitted, the script
    auto-detects it via https://api.ipify.org.

.EXAMPLE
    .\setup-nsp.ps1 -ResourceGroup rg-notifpoc-dev -StorageAccountName stnotifpocdev
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$StorageAccountName,

    [string]$SubscriptionId,

    [string]$NspName,

    [string]$CallerIp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve optional parameters ────────────────────────────────────────────
if (-not $SubscriptionId) {
    $SubscriptionId = az account show --query id -o tsv
    if ($LASTEXITCODE -ne 0) { throw 'Not logged in to Azure — run az login first.' }
}

if (-not $NspName) {
    $NspName = "nsp-$StorageAccountName"
}

if (-not $CallerIp) {
    try {
        $CallerIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10).Trim()
        Write-Host "  Auto-detected caller IP: $CallerIp" -ForegroundColor White
    } catch {
        throw "Could not detect public IP automatically. Pass -CallerIp <your-ip> explicitly."
    }
}

$location       = az group show -n $ResourceGroup --query location -o tsv
$profileName    = 'default-profile'
$ipRuleName     = 'allow-caller-ip'
$subRuleName    = 'allow-azure-subscription'
$assocName      = "$StorageAccountName-assoc"
$storageId      = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$StorageAccountName"

Write-Host "`n  NSP name    : $NspName"     -ForegroundColor White
Write-Host "  Caller IP   : $CallerIp"      -ForegroundColor White
Write-Host "  Subscription: $SubscriptionId`n" -ForegroundColor White

# ── Ensure the nsp extension is installed ─────────────────────────────────
az config set extension.dynamic_install_allow_preview=true 2>$null | Out-Null

# ── 1. NSP resource ────────────────────────────────────────────────────────
$nspExists = az network perimeter show -n $NspName -g $ResourceGroup --query name -o tsv 2>$null
if ($nspExists) {
    Write-Host "  [skip] NSP '$NspName' already exists." -ForegroundColor DarkGray
} else {
    Write-Host "  Creating NSP '$NspName'..." -ForegroundColor White
    az network perimeter create --name $NspName -g $ResourceGroup --location $location | Out-Null
    Write-Host "  NSP created." -ForegroundColor Green
}

# ── 2. Profile ─────────────────────────────────────────────────────────────
$profileExists = az network perimeter profile show --perimeter-name $NspName -g $ResourceGroup -n $profileName --query name -o tsv 2>$null
if ($profileExists) {
    Write-Host "  [skip] Profile '$profileName' already exists." -ForegroundColor DarkGray
} else {
    Write-Host "  Creating profile '$profileName'..." -ForegroundColor White
    az network perimeter profile create --perimeter-name $NspName -g $ResourceGroup -n $profileName | Out-Null
    Write-Host "  Profile created." -ForegroundColor Green
}

# ── 3. IP access rule ──────────────────────────────────────────────────────
$existingIpRule = az network perimeter profile access-rule list `
    --perimeter-name $NspName -g $ResourceGroup --profile-name $profileName `
    --query "[?contains(addressPrefixes, '$CallerIp/32') || contains(addressPrefixes, '$CallerIp')] | [0].name" -o tsv 2>$null
if ($existingIpRule) {
    Write-Host "  [skip] IP access rule for $CallerIp already exists (as '$existingIpRule')." -ForegroundColor DarkGray
} else {
    Write-Host "  Adding IP access rule for $CallerIp..." -ForegroundColor White
    az network perimeter profile access-rule create `
        --perimeter-name $NspName -g $ResourceGroup --profile-name $profileName `
        -n $ipRuleName --address-prefixes "$CallerIp/32" | Out-Null
    Write-Host "  IP rule added." -ForegroundColor Green
}

# ── 4. Subscription access rule (for Logic Apps / Azure services) ──────────
$subRuleExists = az network perimeter profile access-rule show `
    --perimeter-name $NspName -g $ResourceGroup --profile-name $profileName -n $subRuleName `
    --query name -o tsv 2>$null
if ($subRuleExists) {
    Write-Host "  [skip] Subscription access rule '$subRuleName' already exists." -ForegroundColor DarkGray
} else {
    Write-Host "  Adding subscription access rule for /subscriptions/$SubscriptionId..." -ForegroundColor White
    az network perimeter profile access-rule create `
        --perimeter-name $NspName -g $ResourceGroup --profile-name $profileName `
        -n $subRuleName `
        --subscriptions "[{id:'/subscriptions/$SubscriptionId'}]" | Out-Null
    Write-Host "  Subscription rule added." -ForegroundColor Green
}

# ── 5. Association with storage account ────────────────────────────────────
# Check by private-link resource ID — the association name may differ
$existingAssoc = az network perimeter association list `
    --perimeter-name $NspName -g $ResourceGroup `
    --query "[?privateLinkResource.id=='$storageId'] | [0].name" -o tsv 2>$null

if ($existingAssoc) {
    Write-Host "  [skip] Storage account already associated with NSP (as '$existingAssoc')." -ForegroundColor DarkGray
    # Ensure it is in Enforced mode
    $currentMode = az network perimeter association show `
        -n $existingAssoc --perimeter-name $NspName -g $ResourceGroup --query accessMode -o tsv 2>$null
    if ($currentMode -ne 'Enforced') {
        Write-Host "  Switching association to Enforced mode..." -ForegroundColor White
        az network perimeter association update -n $existingAssoc --perimeter-name $NspName -g $ResourceGroup --access-mode Enforced | Out-Null
        Write-Host "  Enforced." -ForegroundColor Green
    }
} else {
    $profileId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/networkSecurityPerimeters/$NspName/profiles/$profileName"
    Write-Host "  Associating storage account with NSP (Enforced mode)..." -ForegroundColor White
    az network perimeter association create `
        -n $assocName --perimeter-name $NspName -g $ResourceGroup `
        --access-mode Enforced `
        --profile "{id:'$profileId'}" `
        --private-link-resource "{id:'$storageId'}" | Out-Null
    Write-Host "  Association created." -ForegroundColor Green
}

Write-Host "`n  NSP setup complete. Storage account '$StorageAccountName' is reachable from:" -ForegroundColor Green
Write-Host "    • Caller IP:  $CallerIp" -ForegroundColor White
Write-Host "    • Subscription $SubscriptionId (all Azure services / Logic Apps)" -ForegroundColor White
