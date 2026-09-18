$repo=Split-Path $PSScriptRoot
Describe 'Packaged launcher' {
    It 'builds an executable that reports its version without starting setup' {
        & "$repo\packaging\Build.ps1" -LauncherOnly
        $LASTEXITCODE | Should Be 0
        $output=& "$repo\artifacts\payload\perfect-win11.exe" --version
        $LASTEXITCODE | Should Be 0
        $output | Should Be (Get-Content "$repo\VERSION" -Raw).Trim()
    }
    It 'shows help without starting setup' {
        (& "$repo\artifacts\payload\perfect-win11.exe" --help | Out-String) | Should Match '\-\-restore-settings'
        $LASTEXITCODE | Should Be 0
    }
    It 'forwards arguments literally and preserves the caller directory and exit codes' {
        # Use workspace fixtures: this sandbox misroutes child cwd for TEMP's 8.3 alias.
        $fixture=Join-Path $repo ('artifacts\tests\'+[guid]::NewGuid().ToString()+'\launcher fixture')
        [void][IO.Directory]::CreateDirectory($fixture)
        Copy-Item "$repo\artifacts\payload\perfect-win11.exe" $fixture
        @'
param([string]$AppList, [int]$Code=0)
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
@{value=$AppList; cwd=(Get-Location).Path} | ConvertTo-Json -Compress
exit $Code
'@ | Set-Content "$fixture\Setup.ps1" -Encoding UTF8
        $cases=@(
            @{arguments='-AppList "C:\a space\trailing\\"'; value='C:\a space\trailing\'},
            @{arguments='-AppList "https://example.org/list.json?a=1&b=$(whoami);x=2"'; value='https://example.org/list.json?a=1&b=$(whoami);x=2'},
            @{arguments='-AppList "a\"quoted\"value"'; value='a"quoted"value'},
            @{arguments='-AppList ""'; value=''},
            @{arguments='-AppList "café 日本.json"'; value='café 日本.json'}
        )
        foreach ($case in $cases) {
            $start=New-Object Diagnostics.ProcessStartInfo
            $start.FileName="$fixture\perfect-win11.exe"
            $start.Arguments=$case.arguments
            $start.WorkingDirectory=$fixture
            $start.UseShellExecute=$false
            $start.RedirectStandardOutput=$true
            $start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
            $child=[Diagnostics.Process]::Start($start)
            $actual=$child.StandardOutput.ReadToEnd() | ConvertFrom-Json
            $child.WaitForExit()
            $child.ExitCode | Should Be 0
            $actual.value | Should Be $case.value
            $actual.cwd | Should Be $fixture
            $child.Dispose()
        }
        foreach ($code in @(0,1,3010)) {
            & "$fixture\perfect-win11.exe" -Code $code | Out-Null
            $LASTEXITCODE | Should Be $code
        }
        Copy-Item "$fixture\Setup.ps1" "$fixture\Restore-Settings.ps1"
        & "$fixture\perfect-win11.exe" --restore-settings -Code 3010 | Out-Null
        $LASTEXITCODE | Should Be 3010
    }
    It 'reports an incomplete installation without starting PowerShell' {
        $fixture=Join-Path $TestDrive 'missing payload'
        [void][IO.Directory]::CreateDirectory($fixture)
        Copy-Item "$repo\artifacts\payload\perfect-win11.exe" $fixture
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName="$fixture\perfect-win11.exe"
        $start.UseShellExecute=$false
        $start.RedirectStandardError=$true
        $child=[Diagnostics.Process]::Start($start)
        $errorText=$child.StandardError.ReadToEnd()
        $child.WaitForExit()
        $child.ExitCode | Should Be 1
        $errorText | Should Match 'Reinstall'
        $child.Dispose()
    }
}
Describe 'Shared operation lock' {
    It 'accepts an unowned retained handle and recovers from an abandoned owner' {
        Import-Module "$repo\lib\Operation.psm1" -Force
        $oldLocal=$env:LOCALAPPDATA
        $env:LOCALAPPDATA=Join-Path $TestDrive 'abandoned user'
        $name='Global\PerfectWin11.Package.'+$env:LOCALAPPDATA.ToLowerInvariant().Replace('\','_').Replace(':','_')
        $retained=New-Object Threading.Mutex($false,$name)
        try {
            $operation=Enter-PerfectWin11Operation
            Exit-PerfectWin11Operation $operation
            $command="`$m=New-Object Threading.Mutex(`$false,'$name'); [void]`$m.WaitOne(); [Environment]::Exit(0)"
            $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
            $LASTEXITCODE | Should Be 0
            $operation=Enter-PerfectWin11Operation
            Exit-PerfectWin11Operation $operation
        } finally { $retained.Dispose(); $env:LOCALAPPDATA=$oldLocal }
    }
    It 'rejects a second process and releases ownership without creating state files' {
        Import-Module "$repo\lib\Operation.psm1" -Force
        $oldLocal=$env:LOCALAPPDATA
        $env:LOCALAPPDATA=Join-Path $TestDrive 'isolated user'
        $operation=$null
        try {
            $operation=Enter-PerfectWin11Operation
            $command="`$ProgressPreference='SilentlyContinue'; Import-Module '$repo\lib\Operation.psm1'; try { `$m=Enter-PerfectWin11Operation; Exit-PerfectWin11Operation `$m; exit 0 } catch { exit 23 }"
            $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
            $LASTEXITCODE | Should Be 23
            Exit-PerfectWin11Operation $operation; $operation=$null
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
            $LASTEXITCODE | Should Be 0
            Test-Path $env:LOCALAPPDATA | Should Be $false
        } finally { Exit-PerfectWin11Operation $operation; $env:LOCALAPPDATA=$oldLocal }
    }
}
Describe 'Build staging boundaries' {
    It 'does not delete payloads through a redirected artifacts directory' {
        $fixture=Join-Path $repo ('artifacts\tests\'+[guid]::NewGuid().ToString())
        [void][IO.Directory]::CreateDirectory("$fixture\project\packaging")
        [void][IO.Directory]::CreateDirectory("$fixture\other\payload")
        Copy-Item "$repo\packaging\Build.ps1" "$fixture\project\packaging\Build.ps1"
        Set-Content "$fixture\project\VERSION" '0.1.0'
        Set-Content "$fixture\other\payload\sentinel" 'keep me'
        New-Item -ItemType Junction -Path "$fixture\project\artifacts" -Target "$fixture\other" | Out-Null
        { & "$fixture\project\packaging\Build.ps1" -LauncherOnly } | Should Throw
        Get-Content "$fixture\other\payload\sentinel" | Should Be 'keep me'
    }
}
