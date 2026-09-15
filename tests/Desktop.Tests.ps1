Import-Module "$PSScriptRoot\..\lib\Desktop.psm1" -Force

Describe 'Targeted JSON restoration' {
    BeforeEach {
        $state=New-SetupState @{schemaVersion=1; windows=@(); wsl=@()} @() @() 'user'
        $path=Join-Path $TestDrive 'state.json'
        $target=Join-Path $TestDrive 'settings.json'
    }
    It 'restores only defaultProfile and keeps subsequent edits and profiles' {
        Write-Json $target @{defaultProfile='original'; theme='dark'; profiles=@{list=@(@{name='custom'})}}
        Save-FileBackup $state $path $target
        Write-Json $target @{defaultProfile='managed'; theme='light'; profiles=@{list=@(@{name='custom'},@{name='Ubuntu'})}}
        $record=Get-JsonRestoreRecord $state $target defaultProfile
        $current=Read-Json $target
        $current.defaultProfile=$record.value; Write-Json $target $current
        $read=Read-Json $target
        $read.defaultProfile | Should Be 'original'
        $read.theme | Should Be 'light'
        $read.profiles.list.Count | Should Be 2
    }
    It 'retains the first backup over multiple on/off cycles' {
        Save-JsonPropertyBackup $state $path $target startup @{startup=$false; unrelated=1}
        Save-JsonPropertyBackup $state $path $target startup @{startup=$true; unrelated=2}
        $state.backups.Count | Should Be 1
        (Get-JsonRestoreRecord $state $target startup).value | Should Be $false
    }
    It 'reports missing legacy backups instead of capturing the current managed value' {
        Write-Json $target @{startup=$true}
        { Get-JsonRestoreRecord $state $target startup } | Should Throw
        $state.backups += @{kind='file'; target=$target; existed=$true; copy=(Join-Path $TestDrive 'missing')}
        { Get-JsonRestoreRecord $state $target startup } | Should Throw
    }
    It 'remembers absent original properties' {
        Write-Json $target @{theme='light'}
        Save-FileBackup $state $path $target
        (Get-JsonRestoreRecord $state $target defaultProfile).existed | Should Be $false
    }
}

InModuleScope Desktop {
    Describe 'Independent reconfiguration batches' {
        BeforeEach {
            $state=New-SetupState @{schemaVersion=1; windows=@(); wsl=@()} @() @() 'user'
            $state.setupComplete=$true
            foreach ($id in $state.appliedSettings.Keys | ForEach-Object { $_ }) { $state.appliedSettings[$id]=$true }
            $path=Join-Path $TestDrive 'batch.json'
            Mock Set-ManagedDesktopSetting { param($State,$Path,$Id,$Enabled) $State.appliedSettings[$Id]=$Enabled }
        }
        It 'blocks reconfiguration of an incomplete setup' {
            $state.setupComplete=$false
            { New-Reconfiguration $state $state.settings } | Should Throw
        }
        It 'only includes changed desktop settings' {
            $desired=$state.settings.Clone(); $desired.taskbar=$false
            $batch=New-Reconfiguration $state $desired
            $batch.actions.Count | Should Be 1
            $batch.actions[0].setting | Should Be 'taskbar'
            $batch.actions[0].enabled | Should Be $false
        }
        It 'leaves original setup steps and versions intact' {
            $state.steps['linux-install']=@{status='done'; error=$null}
            $state.versions.package='1.2.3'
            $desired=$state.settings.Clone(); $desired.taskbar=$false
            $state.reconfiguration=New-Reconfiguration $state $desired
            Invoke-Reconfiguration $state $path | Should Be $true
            $state.steps['linux-install'].status | Should Be 'done'
            $state.versions.package | Should Be '1.2.3'
            $state.history.Count | Should Be 1
            ($null -eq $state.reconfiguration) | Should Be $true
            $state.settings.taskbar | Should Be $false
        }
        It 'retries only failed actions after process state reload' {
            Mock Set-ManagedDesktopSetting {
                param($State,$Path,$Id,$Enabled)
                if ($Id -eq 'taskbar') { throw 'restore unavailable' }
                $State.appliedSettings[$Id]=$Enabled
            }
            $desired=$state.settings.Clone(); $desired.taskbar=$false; $desired.ads=$false
            $state.reconfiguration=New-Reconfiguration $state $desired
            Invoke-Reconfiguration $state $path | Should Be $false
            $read=Read-SetupState $path 'user'
            @($read.reconfiguration.actions | Where-Object status -eq 'failed').Count | Should Be 1
            Mock Set-ManagedDesktopSetting { param($State,$Path,$Id,$Enabled) if ($Id -ne 'taskbar') { throw 'repeated completed action' }; $State.appliedSettings[$Id]=$Enabled }
            Invoke-Reconfiguration $read $path | Should Be $true
            $read.appliedSettings.ads | Should Be $false
            $read.appliedSettings.taskbar | Should Be $false
        }
        It 'retries interrupted running actions' {
            $desired=$state.settings.Clone(); $desired.taskbar=$false
            $state.reconfiguration=New-Reconfiguration $state $desired
            $state.reconfiguration.actions[0].status='running'
            Invoke-Reconfiguration $state $path | Should Be $true
            Assert-MockCalled Set-ManagedDesktopSetting -Times 1
        }
        It 'supports repeated enable and restore cycles without losing history' {
            $desired=$state.settings.Clone(); $desired.taskbar=$false
            $state.reconfiguration=New-Reconfiguration $state $desired
            Invoke-Reconfiguration $state $path | Should Be $true
            $desired.taskbar=$true
            $state.reconfiguration=New-Reconfiguration $state $desired
            Invoke-Reconfiguration $state $path | Should Be $true
            $state.history.Count | Should Be 2
            $state.appliedSettings.taskbar | Should Be $true
        }
    }
}

Describe 'Restoration fails before mutation without complete originals' {
    InModuleScope Desktop {
        It 'does not stop the helper if its startup backup is missing' {
            $state=New-SetupState @{schemaVersion=1; windows=@(); wsl=@()} @() @() 'user'
            Mock Stop-ManagedWinTap { throw 'must not stop' }
            { Set-ManagedDesktopSetting $state (Join-Path $TestDrive 'state.json') 'win-tap' $false } | Should Throw
            Assert-MockCalled Stop-ManagedWinTap -Times 0
        }
        It 'does not restore partial distraction backups' {
            $state=New-SetupState @{schemaVersion=1; windows=@(); wsl=@()} @() @() 'user'
            $state.backups += @{kind='registry'; target='HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; name='Enabled'; existed=$true; value=1; type='DWord'}
            Mock Restore-RegistryRecord { throw 'must not restore partial setting' }
            { Set-ManagedDesktopSetting $state (Join-Path $TestDrive 'state.json') ads $false } | Should Throw
            Assert-MockCalled Restore-RegistryRecord -Times 0
        }
    }
}

InModuleScope Desktop {
    Describe 'Initial desktop opt-outs' {
        BeforeEach {
            $state=New-SetupState @{schemaVersion=1; windows=@(); wsl=@()} @() @() 'user'
            $path=Join-Path $TestDrive 'state.json'
            Mock Set-ManagedDesktopSetting { param($State,$Path,$Id,$Enabled) $State.appliedSettings[$Id]=$Enabled }
        }
        It 'does not mutate any desktop option when all are unchecked' {
            foreach ($id in @($state.settings.Keys)) { $state.settings[$id]=$false }
            Invoke-InitialDesktopSettings $state $path
            Invoke-InitialDesktopSettings $state $path -TerminalOnly
            Assert-MockCalled Set-ManagedDesktopSetting -Times 0
            (Test-Path $path) | Should Be $false
        }
        It 'only applies the one selected option and defers Terminal until ready' {
            foreach ($id in @($state.settings.Keys)) { $state.settings[$id]=$false }
            $state.settings['terminal-default']=$true
            Invoke-InitialDesktopSettings $state $path
            Assert-MockCalled Set-ManagedDesktopSetting -Times 0
            Invoke-InitialDesktopSettings $state $path -TerminalOnly
            Assert-MockCalled Set-ManagedDesktopSetting -Times 1 -ParameterFilter { $Id -eq 'terminal-default' }
        }
        It 'does not configure the helper or startup when PowerToys failed' {
            foreach ($id in @($state.settings.Keys)) { $state.settings[$id]=$false }
            $state.settings['win-tap']=$true; $state.settings['powertoys-startup']=$true
            Invoke-InitialDesktopSettings $state $path $false
            Assert-MockCalled Set-ManagedDesktopSetting -Times 0 -Scope It
        }
    }
}

InModuleScope Desktop {
    Describe 'JSON changes preserve unrelated user preferences' {
        BeforeEach {
            $state=New-SetupState @{schemaVersion=1; windows=@(); wsl=@()} @() @() 'user'
            $path=Join-Path $TestDrive 'state.json'
            $target=Join-Path $TestDrive 'terminal.json'
            Mock Get-SettingJsonTarget { @{target=(Join-Path $TestDrive 'terminal.json'); name='defaultProfile'} }
        }
        It 'restores the original default after repeated actual setting operations' {
            Write-Json $target @{defaultProfile='custom'; theme='dark'; profiles=@{list=@(@{name='custom'})}}
            Set-JsonSetting $state $path 'terminal-default' $true
            $current=Read-Json $target; $current.theme='light'; $current.profiles.list += @{name='later'}; Write-Json $target $current
            Set-JsonSetting $state $path 'terminal-default' $false
            Set-JsonSetting $state $path 'terminal-default' $true
            Set-JsonSetting $state $path 'terminal-default' $false
            $read=Read-Json $target
            $read.defaultProfile | Should Be 'custom'
            $read.theme | Should Be 'light'
            $read.profiles.list.Count | Should Be 2
            $state.backups.Count | Should Be 1
        }
        It 'removes just an originally absent defaultProfile property' {
            Write-Json $target @{theme='light'; profiles=@{list=@()}}
            Set-JsonSetting $state $path 'terminal-default' $true
            Set-JsonSetting $state $path 'terminal-default' $false
            $read=Read-Json $target
            $read.ContainsKey('defaultProfile') | Should Be $false
            $read.theme | Should Be 'light'
        }
    }
}

Describe 'Reconfiguration previews are read-only' {
    BeforeEach { $originalLocalAppData=$env:LOCALAPPDATA; $env:LOCALAPPDATA=$TestDrive }
    AfterEach { $env:LOCALAPPDATA=$originalLocalAppData }
    It 'previews reconfiguration without migrating the saved file on disk' {
        $path=Join-Path $TestDrive 'PerfectWin11\state.json'
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $state=New-SetupState @{schemaVersion=1; windows=@(); wsl=@()} @() @() $sid
        $state.setupComplete=$true
        foreach ($id in @($state.appliedSettings.Keys)) { $state.appliedSettings[$id]=$true }
        Write-Json $path $state
        $before=Get-Content $path -Raw
        $output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\..\Setup.ps1" -Reconfigure -WhatIf 2>&1
        $LASTEXITCODE | Should Be 0
        ($output -join "`n") | Should Match 'Preview only'
        (Get-Content $path -Raw) | Should Be $before
        $stateDir=Split-Path $path
        @(Get-ChildItem $stateDir -Filter '*.log').Count | Should Be 0
    }
}

InModuleScope Desktop {
    Describe 'Restore exactly the managed targets' {
        It 'ignores unrelated registry backups during a distraction restore' {
            $state=New-SetupState @{schemaVersion=1; windows=@(); wsl=@()} @() @() 'user'
            foreach ($item in Get-SettingRegistryTargets ads) {
                $state.backups += @{kind='registry'; target=$item.target; name=$item.name; existed=$true; value=1; type='DWord'}
            }
            $state.backups += @{kind='registry'; target='HKCU:\Unrelated'; name='untouched'; existed=$true; value=123; type='DWord'}
            Mock Restore-RegistryRecord {}
            Set-ManagedDesktopSetting $state (Join-Path $TestDrive 'restore.json') ads $false
            Assert-MockCalled Restore-RegistryRecord -Times 4 -Scope It
            Assert-MockCalled Restore-RegistryRecord -Times 0 -Scope It -ParameterFilter { $Record.name -eq 'untouched' }
        }
        It 'stops only the managed helper in the current session' {
            Mock Get-Process { [pscustomobject]@{SessionId=1} }
            Mock Get-CimInstance {
                $target=Join-Path $TestDrive 'WinTap.ahk'
                @([pscustomobject]@{SessionId=1;ProcessId=101;CommandLine=('"AutoHotkey64.exe" "'+$target+'"')},
                  [pscustomobject]@{SessionId=1;ProcessId=102;CommandLine='"AutoHotkey64.exe" "C:\unrelated\WinTap.ahk"'},
                  [pscustomobject]@{SessionId=2;ProcessId=103;CommandLine=('"AutoHotkey64.exe" "'+$target+'"')})
            }
            Mock Stop-Process {}
            Stop-ManagedWinTap (Join-Path $TestDrive 'state.json')
            Assert-MockCalled Stop-Process -Times 1 -Scope It -ParameterFilter { $Id -eq 101 }
            Assert-MockCalled Stop-Process -Times 0 -Scope It -ParameterFilter { $Id -in @(102,103) }
        }
    }
}
