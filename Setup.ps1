#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$AppList, [switch]$Resume)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot\lib\Core.psm1" -Force
Import-Module "$PSScriptRoot\lib\Windows.psm1" -Force
Import-Module "$PSScriptRoot\lib\Wsl.psm1" -Force

$stateDir=Join-Path $env:LOCALAPPDATA 'PerfectWin11'
$statePath=Join-Path $stateDir 'state.json'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$resumeCommand='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Resume'
$lock=$null; $transcript=$false; $exitCode=0
try {
    if ($Resume -and $AppList) { throw '-Resume and -AppList cannot be combined: resume uses the saved manifest.' }
    if (-not $WhatIfPreference) {
        $principal=New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Start Setup.ps1 from a normal, non-elevated PowerShell window as the intended desktop user. Individual operations request UAC.' }
    }
    if (Test-Path $statePath) {
        if ($AppList) { throw 'A saved setup exists. Resume it, or archive %LOCALAPPDATA%\PerfectWin11 before selecting a new manifest.' }
        $state=Read-SetupState $statePath $sid
        Write-Host 'Using saved manifest, choices, and resolved versions.'
    } else {
        if ($Resume) { throw "No saved setup found at $statePath" }
        $manifest=if ($AppList) { Read-Manifest $AppList } else { @{schemaVersion=1; windows=@(); wsl=@()} }
        $install=Merge-InstallCatalog (Get-InstallCatalog) $manifest
        $remove=@(Get-RemovalCatalog)
        if (-not $WhatIfPreference) {
            $remove=Select-Checklist 'Remove apps / disable distractions' $remove
            $install=Select-Checklist 'Install packages / features' $install
        }
        # Display forced dependencies in the final summary before approval.
        $features=@($install | Where-Object { $_.selected -and $_.kind -eq 'feature' } | ForEach-Object { $_.id })
        if ('runtimes' -in $features -or 'starship' -in $features) { ($install | Where-Object { $_.kind -eq 'feature' -and $_.id -eq 'mise' }).selected=$true }
        $dependencies=@('ca-certificates','curl')
        if ('runtimes' -in $features) { $dependencies += @('build-essential','pkg-config','libssl-dev','zlib1g-dev','libbz2-dev','libreadline-dev','libsqlite3-dev','libffi-dev','liblzma-dev','libyaml-dev','libgdbm-dev','libncurses-dev','uuid-dev','tk-dev') }
        foreach ($item in $install) { if ($item.kind -eq 'wsl' -and $item.id -in $dependencies) { $item.selected=$true } }
        $state=New-SetupState $manifest $install $remove $sid
        if (-not $WhatIfPreference) { Test-Preflight; Select-WslDistribution $state }
    }
    Write-Host "`nChanges for this setup:"
    $state.remove | Where-Object selected | ForEach-Object { Write-Host "  Remove/disable $($_.kind): $($_.id)" }
    $state.install | Where-Object selected | ForEach-Object { Write-Host "  Install $($_.kind): $($_.id)" }
    Write-Host "  Enable WSL2, initialize/reuse $($state.distro), enable systemd, set default WSL/Terminal profile."
    Write-Host '  Enable taskbar auto-hide, PowerToys startup/Command Palette, and Win-tap helper at login.'
    Write-Host '  Stop PowerToys briefly; restart only the selected Ubuntu distro after enabling systemd.'
    Write-Host '  Remove selected Appx apps for this user and their provisioning for future users.'
    if (@($state.remove | Where-Object { $_.id -eq 'widgets' -and $_.selected }).Count) { Write-Host '  Disable Widgets using its machine policy and hide its taskbar entry for this user.' }
    Write-Host '  Accept selected package licenses/source agreements. Docker selection grants Linux root-equivalent access.'
    Write-Host "  Save state, backups and logs to $stateDir. Never reboot Windows automatically."
    if ($WhatIfPreference) {
        Write-Host 'Preview only: no changes, downloads of packages, state writes, elevation or distro launches. Versions resolve during execution.'
        return
    }
    if (Test-Path $statePath) { Test-Preflight }
    if ((Read-Host 'Type APPLY to execute the summary (anything else cancels)') -cne 'APPLY') { return }
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME,'Apply the selected Perfect Win11 setup')) { return }
    [IO.Directory]::CreateDirectory($stateDir) | Out-Null
    $lock=[IO.File]::Open((Join-Path $stateDir 'setup.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    Write-Json $statePath $state
    Start-Transcript -Path (Join-Path $stateDir ('setup-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')) | Out-Null
    $transcript=$true
    $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    if ($state.rebootBoot -and $state.rebootBoot -eq $boot) {
        Write-Host "Restart Windows when ready, then run:`n$resumeCommand"
        $exitCode=3010
    } else {
        $state.rebootBoot=$null
        if (-not (Invoke-Step $state $statePath 'winget' { Install-WinGet } { [bool](Get-Command winget.exe -ErrorAction SilentlyContinue) })) { throw 'WinGet is required; fix bootstrap and resume.' }
        foreach ($item in @($state.install | Where-Object { $_.selected -and $_.kind -eq 'windows' })) {
            $id=$item.id
            [void](Invoke-Step $state $statePath "install:$id" { Install-WinGetPackage $state $statePath $id } { Test-WinGetPackage $id })
        }
        [void](Invoke-Step $state $statePath 'windows-inventory' { Save-WinGetInventory $state $statePath } { $false })
        foreach ($item in @($state.remove | Where-Object selected)) {
            $id=$item.id; $kind=$item.kind
            [void](Invoke-Step $state $statePath "remove:$kind`:$id" {
                if ($kind -eq 'setting') { Set-DesktopOption $state $statePath $id; return }
                $record=@{identity=$id; kind=$kind; at=(Get-Date).ToString('o'); status='started'; packages=@()}
                $state.removals += $record; Write-Json $statePath $state
                if ($kind -eq 'appx') {
                    $packages=@(Get-AppxPackage | Where-Object Name -CEQ $id)
                    $record.packages=@($packages | ForEach-Object { $_.PackageFullName }); Write-Json $statePath $state
                    foreach ($package in $packages) { Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop }
                    [void](Invoke-Machine Deprovision $id)
                } elseif ($kind -eq 'desktop' -and (Test-WinGetPackage $id)) {
                    Invoke-Native winget.exe @('uninstall','--id',$id,'--exact','--source','winget','--silent','--disable-interactivity','--accept-source-agreements')
                }
                $record.status='done'; Write-Json $statePath $state
            })
        }
        [void](Invoke-Step $state $statePath 'taskbar' { Set-Taskbar $state $statePath })
        $ptOk=Invoke-Step $state $statePath 'powertoys-settings' { Set-PowerToys $state $statePath }
        if ($ptOk) { [void](Invoke-Step $state $statePath 'win-tap' { Install-WinTap $state $statePath }) }
        $featuresOk=Invoke-Step $state $statePath 'wsl-features' {
            $code=Invoke-Machine Features
            if ($code -eq 3010) { $state.rebootBoot=$boot; Write-Json $statePath $state }
        }
        if ($state.rebootBoot) {
            Write-Host "Restart Windows when ready, then run:`n$resumeCommand"
            $exitCode=3010
        } elseif ($featuresOk) {
            $wslOk=Invoke-Step $state $statePath 'wsl-update' { Invoke-Native wsl.exe @('--update'); Invoke-Native wsl.exe @('--set-default-version','2') }
            if ($wslOk) { $wslOk=Invoke-Step $state $statePath 'wsl-user' { Initialize-WslUser $state $statePath } }
            if ($wslOk) {
                $pythonOk=Invoke-Step $state $statePath 'wsl-python-bootstrap' {
                    Invoke-Native wsl.exe @('-d',$state.distro,'-u','root','--','apt-get','update')
                    Invoke-Native wsl.exe @('-d',$state.distro,'-u','root','--','apt-get','install','-y','python3','ca-certificates')
                } {
                    & wsl.exe -d $state.distro -u root -- python3 --version 2>&1 | Out-Null
                    $LASTEXITCODE -eq 0
                }
                if (-not $pythonOk) { throw 'Ubuntu system Python bootstrap failed. Resume after fixing APT connectivity.' }
                $systemdOk=Invoke-Step $state $statePath 'wsl-systemd' { Invoke-LinuxPhase $state $statePath systemd; Invoke-Native wsl.exe @('--terminate',$state.distro) }
                if ($systemdOk) {
                    [void](Invoke-Step $state $statePath 'linux-install' { Invoke-LinuxPhase $state $statePath install })
                    [void](Invoke-Step $state $statePath 'linux-verify' { Invoke-LinuxPhase $state $statePath verify })
                }
                [void](Invoke-Step $state $statePath 'terminal-profile' { Set-Terminal $state $statePath })
                if (@($state.install | Where-Object { $_.id -eq 'Microsoft.VisualStudioCode' -and $_.selected }).Count) {
                    [void](Invoke-Step $state $statePath 'vscode-wsl' {
                        $codeCmd=@("$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd","$env:ProgramFiles\Microsoft VS Code\bin\code.cmd") | Where-Object { Test-Path $_ } | Select-Object -First 1
                        if (-not $codeCmd) { throw 'VS Code CLI not found.' }
                        Invoke-Native $codeCmd @('--install-extension','ms-vscode-remote.remote-wsl')
                        $extensions=Invoke-Native $codeCmd @('--list-extensions') -Capture
                        if ($extensions -notmatch '(?m)^ms-vscode-remote\.remote-wsl\s*$') { throw 'WSL extension verification failed.' }
                    })
                }
            }
        }
        $failed=@($state.steps.Keys | Where-Object { $state.steps[$_].status -in @('failed','running') })
        if ($failed.Count) {
            Write-Host "`nUnfinished steps:"
            foreach ($name in $failed) { Write-Host "  ${name}: $($state.steps[$name].error)" }
            if ($exitCode -eq 0) { $exitCode=1 }
        }
        Write-Host "`nState and logs: $stateDir`nRetry/resume: $resumeCommand"
        Write-Host 'Sign out/in for shell policies and login startup. See VALIDATION.md for keyboard and VS Code connection checks.'
    }
} catch {
    Write-Error $_ -ErrorAction Continue
    Write-Host "Resume after resolving the error: $resumeCommand"
    $exitCode=1
} finally {
    if ($transcript) { Stop-Transcript | Out-Null }
    if ($lock) { $lock.Dispose() }
}
exit $exitCode
