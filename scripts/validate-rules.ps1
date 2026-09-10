<#
.SYNOPSIS
    Validates routing-rules.json against routing-schema.json.

.EXAMPLE
    .\scripts\validate-rules.ps1
#>
[CmdletBinding()]
param (
    [string]$RulesFile,
    [string]$SchemaFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $RulesFile) {
    $RulesFile = Join-Path $projectRoot 'config\routing-rules.json'
}
if (-not $SchemaFile) {
    $SchemaFile = Join-Path $projectRoot 'config\routing-schema.json'
}

if (-not (Test-Path $RulesFile)) {
    throw "Routing rules file not found: $RulesFile"
}
if (-not (Test-Path $SchemaFile)) {
    throw "Routing schema file not found: $SchemaFile"
}

$rulesJson = Get-Content $RulesFile -Raw
if (-not ($rulesJson | Test-Json -SchemaFile $SchemaFile)) {
    throw "Routing rules failed schema validation: $RulesFile"
}

$rules = $rulesJson | ConvertFrom-Json
Write-Host "Schema validation passed. Rules: $($rules.rules.Count)" -ForegroundColor Green
