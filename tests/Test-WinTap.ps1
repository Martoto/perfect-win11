#Requires -Version 5.1
[CmdletBinding()]
param([string]$AutoHotkeyPath)
$ErrorActionPreference='Stop'
if (-not $AutoHotkeyPath) {
    $AutoHotkeyPath=@("$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe", "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe") |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $AutoHotkeyPath) { throw 'AutoHotkey v2 is required for this test. Supply -AutoHotkeyPath if installed elsewhere.' }
Import-Module "$PSScriptRoot\..\lib\Windows.psm1" -Force
Test-AutoHotkeyScript $AutoHotkeyPath (Join-Path $PSScriptRoot '..\assets\WinTap.ahk')
Write-Host 'PASS: WinTap.ahk loads in the AutoHotkey interpreter. No hotkeys were activated.'
