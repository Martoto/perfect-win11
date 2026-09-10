# This worker intentionally has no user-settings, WSL registration or arbitrary-command action.
# Elevation executes this reviewed project code, not commands from the app manifest.
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Features','Deprovision','WidgetsDisable','WidgetsRestore')][string]$Action,
    [string]$Identity
)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\Core.psm1" -Force
try {
    switch ($Action) {
        'WidgetsDisable' {
            $key='HKLM:\SOFTWARE\Policies\Microsoft\Dsh'
            if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
            New-ItemProperty -Path $key -Name AllowNewsAndInterests -Value 0 -PropertyType DWord -Force | Out-Null
        }
        'WidgetsRestore' {
            $key='HKLM:\SOFTWARE\Policies\Microsoft\Dsh'
            if ($Identity -eq 'absent') { Remove-ItemProperty -Path $key -Name AllowNewsAndInterests -ErrorAction SilentlyContinue }
            else {
                [uint32]$value=0
                if (-not [uint32]::TryParse($Identity,[ref]$value)) { throw 'Invalid saved Widgets policy value.' }
                if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
                New-ItemProperty -Path $key -Name AllowNewsAndInterests -Value $value -PropertyType DWord -Force | Out-Null
            }
        }
        'Features' {
            $restart = $false
            foreach ($name in @('Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform')) {
                $feature = Get-WindowsOptionalFeature -Online -FeatureName $name
                if ($feature.State -eq 'EnablePending') { $restart=$true }
                elseif ($feature.State -ne 'Enabled') {
                    $result = Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart
                    if ($result.RestartNeeded) { $restart=$true }
                }
            }
            if ($restart) { exit 3010 }
        }
        'Deprovision' {
            $allowed = @(Get-RemovalCatalog | Where-Object { $_.kind -eq 'appx' -and $_.id -ceq $Identity })
            if ($allowed.Count -ne 1) { throw 'Identity is not in the fixed removal catalog.' }
            Get-AppxProvisionedPackage -Online | Where-Object DisplayName -CEQ $Identity | ForEach-Object {
                Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null
            }
        }
    }
    exit 0
} catch { Write-Error $_ -ErrorAction Continue; exit 1 }
