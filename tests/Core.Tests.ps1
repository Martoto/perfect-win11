Import-Module "$PSScriptRoot\..\lib\Core.psm1" -Force
Import-Module "$PSScriptRoot\..\lib\Windows.psm1" -Force

Describe 'Package manifest boundary' {
    It 'accepts the shipped example' {
        $m=Read-Manifest "$PSScriptRoot\..\app-list.example.json"
        $m.schemaVersion | Should Be 1
        $m.windows.Count | Should Be 2
    }
    It 'accepts empty arrays' { { Assert-Manifest @{schemaVersion=1; windows=@(); wsl=@()} } | Should Not Throw }
    It 'rejects shell injection and package options' {
        foreach ($bad in @('git; reboot','$(id)','--yes',"git`n",'git`nreboot','git=1.0','ppa:user/repo')) {
            { Assert-Manifest @{schemaVersion=1; windows=@(); wsl=@($bad)} } | Should Throw
        }
    }
    It 'rejects command and repository fields' {
        foreach ($field in @('commands','repositories','script')) {
            $m=@{schemaVersion=1; windows=@(); wsl=@()}; $m[$field]=@('untrusted')
            { Assert-Manifest $m } | Should Throw
        }
    }
    It 'rejects incorrect types, unsupported schemas, missing fields, and overlong lists' {
        foreach ($m in @(@{schemaVersion='1'; windows=@(); wsl=@()},@{schemaVersion=2; windows=@(); wsl=@()},@{schemaVersion=1; windows='Microsoft.PowerToys'; wsl=@()},@{schemaVersion=1; windows=@()},@{schemaVersion=1; windows=@(); wsl=@('git')*201})) {
            { Assert-Manifest $m } | Should Throw
        }
    }
    It 'rejects HTTP without downloading it' { { Read-Manifest 'http://example.com/list.json' } | Should Throw }
    It 'deduplicates case-insensitively while preserving required choices' {
        $m=@{schemaVersion=1; windows=@('microsoft.powertoys','7zip.7zip','7zip.7zip'); wsl=@('git','git')}
        $items=Merge-InstallCatalog (Get-InstallCatalog) $m
        @($items | Where-Object id -eq 'Microsoft.PowerToys').Count | Should Be 1
        ($items | Where-Object id -eq 'Microsoft.PowerToys').required | Should Be $true
        @($items | Where-Object id -eq 'git').Count | Should Be 1
        @($items | Where-Object id -eq '7zip.7zip').Count | Should Be 1
    }
    It 'never offers protected identities for removal' {
        $ids=@(Get-RemovalCatalog | ForEach-Object { $_.id })
        foreach ($id in @('Microsoft.WindowsStore','Microsoft.DesktopAppInstaller','Microsoft.MicrosoftEdge','Microsoft.SecHealthUI','MicrosoftWindows.Client.CBS')) { ($id -in $ids) | Should Be $false }
        foreach ($id in @('Microsoft.OneDrive','Microsoft.GamingApp','MSTeams','Microsoft.OutlookForWindows','Microsoft.Copilot')) { (Get-RemovalCatalog | Where-Object id -eq $id).selected | Should Be $false }
    }
}

Describe 'Durable state and independent failure handling' {
    BeforeEach {
        $path=Join-Path $TestDrive 'state.json'
        $m=@{schemaVersion=1; windows=@(); wsl=@()}
        $state=New-SetupState $m (Get-InstallCatalog) (Get-RemovalCatalog) 'test-user'
    }
    It 'round-trips selections, arrays and pinned versions' {
        $state.install[3].selected=$false; $state.versions['Microsoft.PowerToys']='1.2.3'
        Write-Json $path $state
        $read=Read-SetupState $path 'test-user'
        $read.install[3].selected | Should Be $false
        $read.versions['Microsoft.PowerToys'] | Should Be '1.2.3'
        ($read.manifest.wsl -is [array]) | Should Be $true
    }
    It 'rejects state belonging to another initiating user' {
        Write-Json $path $state
        { Read-SetupState $path 'other-user' } | Should Throw
    }
    It 'rejects tampered removal selections' {
        $state.remove += @{id='Microsoft.WindowsStore'; kind='appx'; selected=$true}
        Write-Json $path $state
        { Read-SetupState $path 'test-user' } | Should Throw
    }
    It 'does not re-fetch the manifest on resume' {
        Mock Read-Manifest { throw 'must not fetch' }
        Write-Json $path $state
        $read=Read-SetupState $path 'test-user'
        $read.manifest.schemaVersion | Should Be 1
        Assert-MockCalled Read-Manifest -Times 0
    }
    It 'checkpoints success and skips a completed action' {
        Invoke-Step $state $path 'one' {} | Should Be $true
        Invoke-Step $state $path 'one' { throw 'must not repeat' } | Should Be $true
    }
    It 'retries a failed step and retains unrelated successes' {
        Invoke-Step $state $path 'bad' { throw 'download interrupted' } | Should Be $false
        Invoke-Step $state $path 'good' {} | Should Be $true
        $read=Read-SetupState $path 'test-user'
        $read.steps.bad.error | Should Match 'download interrupted'
        Invoke-Step $read $path 'bad' {} | Should Be $true
        $read.steps.good.status | Should Be 'done'
        $read.steps.bad.status | Should Be 'done'
    }
    It 'retries a step interrupted while running' {
        $state.steps.one=@{status='running'; error=$null}
        Invoke-Step $state $path 'one' {} | Should Be $true
        $state.steps.one.status | Should Be 'done'
    }
    It 'preserves a reboot checkpoint across process state reloads' {
        Mock Invoke-Machine { return 3010 }
        Invoke-Step $state $path 'features' {
            if ((Invoke-Machine Features) -eq 3010) { $state.rebootBoot='2026-09-10T12:00:00Z' }
        } | Should Be $true
        $read=Read-SetupState $path 'test-user'
        $read.rebootBoot | Should Be '2026-09-10T12:00:00Z'
        Invoke-Step $read $path 'features' { throw 'must not repeat before reboot' } | Should Be $true
        Assert-MockCalled Invoke-Machine -Times 1
    }
    It 'skips an already satisfied system operation using a mocked mutation' {
        Mock Invoke-Native { throw 'must not install' }
        Invoke-Step $state $path 'installed' { Invoke-Native winget.exe @('install') } { $true } | Should Be $true
        Assert-MockCalled Invoke-Native -Times 0
        $state.steps.installed.status | Should Be 'satisfied'
    }
    It 'records inventory failures without aborting subsequent steps' {
        Invoke-Step $state $path 'inventory' {} { throw 'source unavailable' } | Should Be $false
        Invoke-Step $state $path 'next' {} | Should Be $true
        $state.steps.inventory.error | Should Match 'source unavailable'
    }
    It 'rechecks satisfaction and repairs previously completed installations' {
        $state.steps.one=@{status='done'; error=$null}
        Invoke-Step $state $path 'one' { throw 'repair attempted' } { $false } | Should Be $false
        $state.steps.one.error | Should Be 'repair attempted'
    }
}

Describe 'Read-only entry-point previews' {
    BeforeEach { $originalLocalAppData=$env:LOCALAPPDATA; $env:LOCALAPPDATA=$TestDrive }
    AfterEach { $env:LOCALAPPDATA=$originalLocalAppData }
    It 'previews merged custom defaults without creating state' {
        $output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\..\Setup.ps1" -WhatIf -AppList "$PSScriptRoot\..\app-list.example.json" 2>&1
        $LASTEXITCODE | Should Be 0
        ($output -join "`n") | Should Match '7zip.7zip'
        (Test-Path (Join-Path $TestDrive 'PerfectWin11')) | Should Be $false
    }
    It 'previews saved choices without fetching a manifest or mutating state' {
        $path=Join-Path $TestDrive 'PerfectWin11\state.json'
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $state=New-SetupState @{schemaVersion=1; windows=@(); wsl=@()} (Get-InstallCatalog) (Get-RemovalCatalog) $sid
        $state.install[3].selected=$false
        Write-Json $path $state
        $before=Get-Content $path -Raw
        $output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\..\Setup.ps1" -Resume -WhatIf 2>&1
        $LASTEXITCODE | Should Be 0
        ($output -join "`n") | Should Not Match 'Install windows: Microsoft.VisualStudioCode'
        (Get-Content $path -Raw) | Should Be $before
    }
}

Describe 'Virtualization preflight' {
    InModuleScope Windows {
        It 'stops before network or mutation when firmware virtualization is unavailable' {
            Mock Get-CimInstance {
                param($ClassName)
                switch ($ClassName) {
                    'Win32_OperatingSystem' { [pscustomobject]@{BuildNumber='26100'; ProductType=1} }
                    'Win32_Processor' { [pscustomobject]@{Architecture=9; VirtualizationFirmwareEnabled=$false; SecondLevelAddressTranslationExtensions=$true} }
                    'Win32_ComputerSystem' { [pscustomobject]@{HypervisorPresent=$false} }
                }
            }
            Mock Invoke-WebRequest { throw 'must not reach network' }
            { Test-Preflight } | Should Throw
            Assert-MockCalled Invoke-WebRequest -Times 0
        }
    }
}

Describe 'WinGet pinned retry' {
    InModuleScope Windows {
        It 'saves the resolved version before a download fails and never resolves it again' {
            $state=New-SetupState @{schemaVersion=1; windows=@(); wsl=@()} @() @() 'test-user'
            $path=Join-Path $TestDrive 'pinned.json'
            Mock Test-WinGetPackage { $true }
            Mock Invoke-Native {
                param($File,$Arguments)
                if ($Arguments[0] -eq 'show') { return "Example`nVersion`n-------`n1.2.3`n1.2.2" }
                throw 'download interrupted'
            }
            { Install-WinGetPackage $state $path 'Example.Package' } | Should Throw
            $read=Read-Json $path
            $read.versions['Example.Package'] | Should Be '1.2.3'
            Mock Invoke-Native {
                param($File,$Arguments)
                if ($Arguments[0] -eq 'show') { throw 'must not re-resolve' }
                if ('1.2.3' -notin $Arguments) { throw 'must use pinned version' }
            }
            { Install-WinGetPackage $read $path 'Example.Package' } | Should Not Throw
        }
    }
}

Describe 'Preserve configuration' {
    It 'reads Terminal JSONC without stripping URLs or commas inside strings' {
        $value=ConvertFrom-Jsonc '{ // comment
          "url": "https://example.com/a,b", "text": ",}", /* comment */ "profiles": { "list": [], },
        }'
        $value.url | Should Be 'https://example.com/a,b'
        $value.text | Should Be ',}'
        ($value.profiles.list -is [array]) | Should Be $true
    }
    It 'refuses malformed configuration rather than overwriting it' {
        { ConvertFrom-Jsonc '{ invalid' } | Should Throw
    }
    It 'backs up each file once and preserves the original through reruns' {
        $path=Join-Path $TestDrive 'state.json'
        $target=Join-Path $TestDrive 'settings.json'
        $state=New-SetupState @{schemaVersion=1; windows=@(); wsl=@()} @() @() 'test-user'
        Set-Content $target 'original'
        Save-FileBackup $state $path $target
        Set-Content $target 'modified'
        Save-FileBackup $state $path $target
        $state.backups.Count | Should Be 1
        (Get-Content $state.backups[0].copy) | Should Be 'original'
    }
}

Describe 'Win-tap helper updates on resume' {
    InModuleScope Windows {
        It 'requires installation when the helper is missing' {
            Test-WinTapInstalled (Join-Path $TestDrive 'state.json') | Should Be $false
        }
        It 'requires reinstalling a stale helper even after the step completed' {
            $path=Join-Path $TestDrive 'state.json'
            $target=Join-Path $TestDrive 'WinTap.ahk'
            Set-Content $target '#MenuMaskKey vkE8'
            Mock Get-ItemPropertyValue { '"AutoHotkey64.exe" "'+(Join-Path $TestDrive 'WinTap.ahk')+'"' }
            $state=New-SetupState @{schemaVersion=1; windows=@(); wsl=@()} @() @() 'test-user'
            $state.steps['win-tap']=@{status='done'; error=$null}
            Invoke-Step $state $path 'win-tap' { throw 'update attempted' } { Test-WinTapInstalled $path } | Should Be $false
            $state.steps['win-tap'].error | Should Be 'update attempted'
        }
        It 'skips an identical helper with its startup registration intact' {
            $path=Join-Path $TestDrive 'state.json'
            Copy-Item (Join-Path $PSScriptRoot '..\assets\WinTap.ahk') (Join-Path $TestDrive 'WinTap.ahk') -Force
            Mock Get-ItemPropertyValue { '"AutoHotkey64.exe" "'+(Join-Path $TestDrive 'WinTap.ahk')+'"' }
            Test-WinTapInstalled $path | Should Be $true
        }
        It 'repairs a missing startup registration even if file content matches' {
            $path=Join-Path $TestDrive 'state.json'
            Copy-Item (Join-Path $PSScriptRoot '..\assets\WinTap.ahk') (Join-Path $TestDrive 'WinTap.ahk') -Force
            Mock Get-ItemPropertyValue { $null }
            Test-WinTapInstalled $path | Should Be $false
        }
    }
}
