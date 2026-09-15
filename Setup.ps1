#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$AppList, [switch]$Resume, [switch]$Reconfigure)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot\lib\Core.psm1" -Force
Import-Module "$PSScriptRoot\lib\Windows.psm1" -Force
Import-Module "$PSScriptRoot\lib\Wsl.psm1" -Force
Import-Module "$PSScriptRoot\lib\Wizard.psm1" -Force
Import-Module "$PSScriptRoot\lib\Desktop.psm1" -Force

$stateDir=Join-Path $env:LOCALAPPDATA 'PerfectWin11'
$statePath=Join-Path $stateDir 'state.json'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$resumeCommand='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Resume'
$lock=$null; $transcript=$false; $exitCode=0; $configuring=$false; $originalHash=$null
try {
    if ($Resume -and $AppList) { throw '-Resume and -AppList cannot be combined: resume uses the saved manifest.' }
    if ($Reconfigure -and ($Resume -or $AppList)) { throw '-Reconfigure cannot be combined with -Resume or -AppList.' }
    if (-not $WhatIfPreference) {
        $principal=New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Start Setup.ps1 from a normal, non-elevated PowerShell window as the intended desktop user. Individual operations request UAC.' }
    }
    if (Test-Path $statePath) {
        if ($AppList) { throw 'A saved setup exists. Resume it, or archive %LOCALAPPDATA%\PerfectWin11 before selecting a new manifest.' }
        $state=Read-SetupState $statePath $sid
        if (-not $WhatIfPreference) { $originalHash=(Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash }
        Write-Host 'Using saved manifest, choices, and resolved versions.'
        if ($Reconfigure) {
            if (-not $state.setupComplete) { throw 'Finish the existing setup with -Resume before reconfiguring desktop settings.' }
            if ($state.reconfiguration) { throw 'A desktop reconfiguration is unfinished. Use -Resume.' }
            $wizard=New-WizardModel $state -Reconfigure
            if (-not $WhatIfPreference -and -not (Show-SetupWizard $wizard)) { Write-Host 'Cancelled; no changes saved.'; return }
            $state.reconfiguration=New-Reconfiguration $state $state.settings
        }
        $configuring=[bool]$state.reconfiguration
    } else {
        if ($Resume -or $Reconfigure) { throw "No saved setup found at $statePath" }
        $manifest=if ($AppList) { Read-Manifest $AppList } else { @{schemaVersion=1; windows=@(); wsl=@()} }
        $install=Merge-InstallCatalog (Get-InstallCatalog) $manifest
        $remove=@(Get-RemovalCatalog)
        $state=New-SetupState $manifest $install $remove $sid
        $wizard=New-WizardModel $state
        if ($WhatIfPreference) { Save-WizardChoices $wizard }
        elseif (-not (Show-SetupWizard $wizard)) { Write-Host 'Cancelled; no changes saved.'; return }
        if (-not $WhatIfPreference) { Test-Preflight; Select-WslDistribution $state }
    }
    Write-Host "`nChanges for this setup:"
    if ($configuring) {
        if ($WhatIfPreference) {
            foreach ($setting in Get-SettingsCatalog) {
                Write-Host "  [$(if ($state.reconfiguration.targetSettings[$setting.id]) {'on'} else {'off'})] $($setting.title)"
            }
        }
        foreach ($action in $state.reconfiguration.actions) {
            $title=(Get-SettingsCatalog | Where-Object id -eq $action.setting).title
            Write-Host "  [$($action.status)] $(if ($action.enabled) {'Apply'} else {'Restore original'}): $title"
            if ($action.setting -eq 'win-tap' -and $action.enabled) { Write-Host '    AutoHotkey v2 will be installed if missing.' }
        }
        Write-Host '  Only desktop/distraction settings change. PowerToys may restart; Widgets may request UAC.'
    } else {
        $reviewLines=Get-WizardReview (New-WizardModel $state)
        foreach ($line in $reviewLines) { Write-Host $line }
        Write-Host "Ubuntu distribution: $($state.distro)"
    }
    Write-Host "  Save state, backups and logs to $stateDir. Never reboot Windows automatically."
    if ($WhatIfPreference) {
        Write-Host 'Preview only: no changes, downloads of packages, state writes, elevation or distro launches. Versions resolve during execution.'
        return
    }
    if ($configuring -and -not $state.reconfiguration.actions.Count) { Write-Host 'No desktop settings changed.'; return }
    if (-not $configuring -and (Test-Path $statePath)) { Test-Preflight }
    if ([Console]::IsInputRedirected) { throw 'Execution approval requires an interactive terminal. Preview with -WhatIf, or rerun interactively.' }
    if ((Read-Host 'Type APPLY to execute the summary (anything else cancels)') -cne 'APPLY') { Write-Host 'Cancelled; no changes saved.'; return }
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME,'Apply the selected Perfect Win11 setup')) { return }
    [IO.Directory]::CreateDirectory($stateDir) | Out-Null
    $lock=[IO.File]::Open((Join-Path $stateDir 'setup.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    if ($originalHash -and (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash -ne $originalHash) { throw 'Saved state changed while reviewing. Rerun to review the latest choices.' }
    if (-not $originalHash -and (Test-Path -LiteralPath $statePath)) { throw 'Another setup created state while reviewing. Rerun with -Resume.' }
    Write-Json $statePath $state
    Start-Transcript -Path (Join-Path $stateDir ('setup-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')) | Out-Null
    $transcript=$true
    if ($configuring) {
        if (-not (Invoke-Reconfiguration $state $statePath)) { throw 'Some desktop settings failed; use -Resume to retry only unfinished changes.' }
        Write-Host "Desktop settings updated. Sign out/in for shell policies.`nState and logs: $stateDir"
        return
    }
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
        foreach ($item in @($state.remove | Where-Object { $_.selected -and $_.kind -ne 'setting' })) {
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
        $ptOk=Invoke-Step $state $statePath 'powertoys-settings' { Set-PowerToys $state $statePath }
        Invoke-InitialDesktopSettings $state $statePath $ptOk
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
                $terminalOk=Invoke-Step $state $statePath 'terminal-profile' { Set-Terminal $state $statePath }
                if ($terminalOk) { Invoke-InitialDesktopSettings $state $statePath -TerminalOnly }
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
        $state.setupComplete=Test-SetupComplete $state
        Write-Json $statePath $state
        if (-not $state.setupComplete -and $exitCode -eq 0) { $exitCode=1 }
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
