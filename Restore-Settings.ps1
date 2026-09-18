#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param()
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot\lib\Operation.psm1" -Force
$operation=$null
try {
$operation=Enter-PerfectWin11Operation
Import-Module "$PSScriptRoot\lib\Core.psm1" -Force
Import-Module "$PSScriptRoot\lib\Windows.psm1" -Force
if (-not $WhatIfPreference) {
    $principal=New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run restoration from a normal, non-elevated PowerShell window as the intended desktop user.' }
}
$statePath=Join-Path $env:LOCALAPPDATA 'PerfectWin11\state.json'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$state=Read-SetupState $statePath $sid
Write-Host 'Exit PowerToys, Windows Terminal and the Win-tap tray helper before restoring. File restoration replaces later edits too.'
foreach ($backup in @($state.backups | Select-Object -Last 10000)) {
    if (-not $PSCmdlet.ShouldProcess(($backup | ConvertTo-Json -Compress),'Restore saved setting')) { continue }
    switch ($backup.kind) {
        'machine-widgets' { [void](Invoke-Machine WidgetsRestore $backup.value) }
        'registry' {
            if ($backup.existed) {
                if (-not (Test-Path -LiteralPath $backup.target)) { New-Item -Path $backup.target -Force | Out-Null }
                New-ItemProperty -LiteralPath $backup.target -Name $backup.name -PropertyType $backup.type -Value $backup.value -Force | Out-Null
            } else { Remove-ItemProperty -LiteralPath $backup.target -Name $backup.name -ErrorAction SilentlyContinue }
        }
        'file' {
            if ($backup.existed) { Copy-Item -LiteralPath $backup.copy -Destination $backup.target -Force }
            elseif (Test-Path -LiteralPath $backup.target) { Remove-Item -LiteralPath $backup.target }
        }
        'taskbar' { Initialize-ShellApi; [PerfectWin11.AppBar]::Set(([PerfectWin11.AppBar]::Get() -band 0xfffffffe) -bor ([uint32]$backup.value -band 1)) }
    }
}
Write-Host 'Sign out/in. Removed apps, provisioning and app data were NOT restored. Linux settings backups are listed in /var/lib/perfect-win11/state.json.'
} finally { Exit-PerfectWin11Operation $operation }
