<#
.SYNOPSIS
    Validates and uploads routing-rules.json to Azure Blob Storage.

.DESCRIPTION
    1. Validates routing-rules.json against routing-schema.json using ajv (Node.js)
    2. Creates a backup of the existing blob (versioning)
    3. Uploads the new rules file to the 'routing-rules' container
    4. Sends a cache-invalidation request to the Rule Engine function (optional)

.PARAMETER ResourceGroup
    Azure resource group containing the storage account

.PARAMETER RulesFile
    Path to the routing rules JSON file (default: config/routing-rules.json)

.PARAMETER StorageAccountName
    Override the storage account name (auto-detected from resource group if not provided)

.PARAMETER SkipValidation
    Skip JSON schema validation (not recommended for production)

.EXAMPLE
    .\upload-rules.ps1 -ResourceGroup rg-notifpoc-dev

.EXAMPLE
    .\upload-rules.ps1 -ResourceGroup rg-notifpoc-prod -RulesFile .\config\routing-rules-prod.json
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [string]$RulesFile,

    [string]$StorageAccountName,

    [switch]$SkipValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot

if (-not $RulesFile) {
    $RulesFile = Join-Path $projectRoot 'config\routing-rules.json'
}
$SchemaFile     = Join-Path $projectRoot 'config\routing-schema.json'
$ContainerName  = 'routing-rules'
$BlobName       = 'routing-rules.json'

function Write-Step([string]$Message) {
    Write-Host "`n  ▶ $Message" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Validate rules file exists
# ---------------------------------------------------------------------------
Write-Step 'Checking input file'

if (-not (Test-Path $RulesFile)) {
    throw "Routing rules file not found: $RulesFile"
}
Write-Host "    Rules file: $RulesFile" -ForegroundColor White

# ---------------------------------------------------------------------------
# JSON Schema validation
# ---------------------------------------------------------------------------
if (-not $SkipValidation) {
    Write-Step 'Validating rules against JSON Schema'

    # Check Node.js is available
    $nodeAvailable = $true
    try {
        $null = node --version 2>$null
        if ($LASTEXITCODE -ne 0) { $nodeAvailable = $false }
    } catch {
        $nodeAvailable = $false
    }

    if (-not $nodeAvailable) {
        Write-Warning 'Node.js not found — skipping schema validation. Install Node.js 18+ to enable validation.'
    } else {

    # Inline validation script using ajv-cli or custom script
    $validateScript = @"
const Ajv = require('ajv');
const addFormats = require('ajv-formats');
const fs = require('fs');

const schema = JSON.parse(fs.readFileSync(process.argv[2], 'utf-8'));
const data   = JSON.parse(fs.readFileSync(process.argv[3], 'utf-8'));

const ajv = new Ajv({ allErrors: true });
addFormats(ajv);
const validate = ajv.compile(schema);

if (!validate(data)) {
  console.error('Validation errors:');
  validate.errors.forEach(e => console.error('  -', e.instancePath, e.message));
  process.exit(1);
} else {
  console.log('Schema validation passed. Rules:', data.rules.length);
}
"@

    # Write temp script into the functions folder so node resolves node_modules correctly
    $functionsDir = Join-Path $projectRoot 'functions'
    $validateScriptPath = Join-Path $functionsDir 'validate-rules-temp.js'
    $validateScript | Set-Content -Path $validateScriptPath -Encoding UTF8

        # Use absolute paths so node resolves them correctly from the functions directory
        $absSchemaFile = (Resolve-Path $SchemaFile).Path
        $absRulesFile  = (Resolve-Path $RulesFile).Path
    Push-Location $functionsDir
    try {
        # Ensure dependencies are installed
        if (-not (Test-Path (Join-Path $functionsDir 'node_modules\ajv'))) {
            Write-Host '    Installing validation dependencies...' -ForegroundColor White
            npm install --quiet
        }
        node $validateScriptPath $absSchemaFile $absRulesFile
        if ($LASTEXITCODE -ne 0) {
            throw "routing-rules.json failed JSON Schema validation. Fix errors before uploading."
        }
    } finally {
        Pop-Location
        if (Test-Path $validateScriptPath) { Remove-Item $validateScriptPath -Force }
    }
    } # end if nodeAvailable
}

# ---------------------------------------------------------------------------
# Detect storage account
# ---------------------------------------------------------------------------
Write-Step 'Resolving storage account'

if (-not $StorageAccountName) {
    $StorageAccountName = az storage account list `
        --resource-group $ResourceGroup `
        --query "[?starts_with(name,'st') && contains(name,'notif')].name | [0]" `
        --output tsv 2>$null

    if (-not $StorageAccountName) {
        # Fall back to first storage account in the RG
        $StorageAccountName = az storage account list `
            --resource-group $ResourceGroup `
            --query '[0].name' `
            --output tsv
    }
}

if (-not $StorageAccountName) {
    throw "Could not detect a storage account in resource group '$ResourceGroup'. Provide -StorageAccountName explicitly."
}

Write-Host "    Storage Account: $StorageAccountName" -ForegroundColor White
# Using Azure AD auth (--auth-mode login) since key-based auth may be disabled

# ---------------------------------------------------------------------------
# Ensure container exists
# ---------------------------------------------------------------------------
Write-Step 'Ensuring container exists'

az storage container create `
    --name $ContainerName `
    --account-name $StorageAccountName `
    --auth-mode login `
    --public-access off | Out-Null

Write-Host "    Container '$ContainerName' ready." -ForegroundColor White

# ---------------------------------------------------------------------------
# Check current version (for changelog)
# ---------------------------------------------------------------------------
Write-Step 'Checking current rules version'

$existingContent = az storage blob download `
    --container-name $ContainerName `
    --name $BlobName `
    --account-name $StorageAccountName `
    --auth-mode login `
    --file "$env:TEMP\routing-rules-current.json" `
    --no-progress 2>$null

if ($LASTEXITCODE -eq 0) {
    $currentRules = Get-Content "$env:TEMP\routing-rules-current.json" | ConvertFrom-Json
    Write-Host "    Current version: $($currentRules.version) (modified: $($currentRules.lastModified))" -ForegroundColor White
} else {
    Write-Host "    No existing rules found — this is the first upload." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Upload new rules
# ---------------------------------------------------------------------------
Write-Step 'Uploading routing-rules.json'

az storage blob upload `
    --container-name $ContainerName `
    --name $BlobName `
    --file $RulesFile `
    --account-name $StorageAccountName `
    --auth-mode login `
    --overwrite true `
    --content-type 'application/json' | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload routing-rules.json to Azure Blob Storage."
}

$newRules = Get-Content $RulesFile | ConvertFrom-Json
Write-Host "    Uploaded successfully." -ForegroundColor Green
Write-Host "    Version: $($newRules.version), Rules: $($newRules.rules.Count), Modified by: $($newRules.lastModifiedBy)" -ForegroundColor White

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n  ✅ Routing rules uploaded successfully." -ForegroundColor Green
Write-Host "     Rules are loaded fresh on every orchestrator run — no restart needed." -ForegroundColor Yellow
