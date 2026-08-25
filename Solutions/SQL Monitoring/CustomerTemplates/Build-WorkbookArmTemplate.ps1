<#
.SYNOPSIS
    Embeds a .workbook file into the matching ARM template's serializedData variable.

.DESCRIPTION
    Keeps CustomerTemplates/arm-template-workbook-v2.json in sync with
    Workbooks/SQLServerMonitoring-v2.workbook. Run this after every workbook edit.

.EXAMPLE
    .\Build-WorkbookArmTemplate.ps1
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$WorkbookPath = (Join-Path $PSScriptRoot '..\Workbooks\SQLServerMonitoring-v2.workbook'),

    [Parameter(Mandatory = $false)]
    [string]$TemplatePath = (Join-Path $PSScriptRoot 'arm-template-workbook-v2.json')
)

$ErrorActionPreference = 'Stop'

$workbookRaw = Get-Content -Path $WorkbookPath -Raw
$workbookObj = $workbookRaw | ConvertFrom-Json          # fails fast on malformed JSON
$compact = $workbookObj | ConvertTo-Json -Depth 100 -Compress

$template = Get-Content -Path $TemplatePath -Raw | ConvertFrom-Json
$template.variables.workbookContent = $compact

$template | ConvertTo-Json -Depth 100 | Set-Content -Path $TemplatePath -Encoding UTF8

Write-Host "Embedded $([System.IO.Path]::GetFileName($WorkbookPath)) into $([System.IO.Path]::GetFileName($TemplatePath))"
Write-Host "  workbook items:    $($workbookObj.items.Count)"
Write-Host "  serialized length: $($compact.Length) chars"
