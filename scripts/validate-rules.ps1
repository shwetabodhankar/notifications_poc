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

$priorities = @($rules.rules | ForEach-Object { $_.priority })
$sortedPriorities = @($priorities | Sort-Object)
if (Compare-Object $priorities $sortedPriorities -SyncWindow 0) {
    throw 'Routing rules must be listed in ascending priority order because the first match wins.'
}

$duplicatePriorities = @($rules.rules | Group-Object priority | Where-Object Count -gt 1)
if ($duplicatePriorities.Count -gt 0) {
    $values = ($duplicatePriorities.Name -join ', ')
    throw "Routing rule priorities must be unique. Duplicates: $values"
}

$lastRule = $rules.rules[-1]
$catchAllConditionValues = @(
    $lastRule.conditions.product,
    $lastRule.conditions.productLine,
    $lastRule.conditions.areaPath,
    $lastRule.conditions.workItemType,
    $lastRule.conditions.isCyberSecurity,
    $lastRule.conditions.isHotfix
)
if ($lastRule.conditions.priority -ne 'Any' -or @($catchAllConditionValues | Where-Object { $null -ne $_ }).Count -gt 0) {
    throw "The last routing rule ('$($lastRule.id)') must be the catch-all rule."
}

Write-Host "Schema validation passed. Rules: $($rules.rules.Count)" -ForegroundColor Green
