#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Frame,[switch]$Reconfigure,[ValidateSet('Desktop','Distractions','App removal','Windows apps','Linux tools','Review')][string]$Screen='Desktop',
    [ValidateRange(50,200)][int]$Width=90,[ValidateRange(16,60)][int]$Height=28)
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot\..\lib\Wizard.psm1" -Force
$state=New-SetupState @{schemaVersion=1; windows=@(); wsl=@()} (Get-InstallCatalog) (Get-RemovalCatalog) 'preview-only'
if ($Reconfigure) {
    $state.setupComplete=$true
    foreach ($id in @($state.appliedSettings.Keys)) { $state.appliedSettings[$id]=$true }
}
$model=New-WizardModel $state -Reconfigure:$Reconfigure
$index=[array]::IndexOf($model.screens,$Screen)
if ($index -lt 0) { throw 'That screen is unavailable in desktop reconfiguration.' }
$model.page=$index
if ($Frame) { $lines=Get-WizardFrame $model $Width $Height; foreach ($line in $lines) { Write-Host $line } }
else { [void](Show-SetupWizard $model); Write-Host 'Preview finished. No settings, selections or packages were saved or changed.' }
