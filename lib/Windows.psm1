Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\Core.psm1"

function Test-Preflight {
    $os = Get-CimInstance Win32_OperatingSystem
    if ([int]$os.BuildNumber -lt 22000 -or $os.ProductType -ne 1 -or -not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
        throw 'Run 64-bit Windows PowerShell 5.1 on Windows 11 Home/Pro.'
    }
    $cpu = @(Get-CimInstance Win32_Processor)[0]
    if ($cpu.Architecture -ne 9) { throw 'This version supports x64 only.' }
    $system = Get-CimInstance Win32_ComputerSystem
    if (-not $system.HypervisorPresent -and (-not $cpu.VirtualizationFirmwareEnabled -or -not $cpu.SecondLevelAddressTranslationExtensions)) {
        throw 'Enable CPU virtualization in firmware (or nested virtualization in the VM host), then rerun.'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($url in @('https://cdn.winget.microsoft.com/cache','https://archive.ubuntu.com/ubuntu/','https://github.com/')) {
        try { Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 20 | Out-Null }
        catch {
            # The CDN root may reject HEAD even though connectivity is healthy.
            if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -notin @(403,404,405)) { throw "Internet preflight failed for ${url}: $_" }
        }
    }
    Write-Host ('WinGet: ' + [bool](Get-Command winget.exe -ErrorAction SilentlyContinue))
}

function Invoke-Machine([string]$Action, [string]$Identity) {
    if ($Action -notin @('Features','Deprovision','WidgetsDisable','WidgetsRestore')) { throw 'Unknown machine action.' }
    if ($Identity -and $Identity -notmatch '^[A-Za-z0-9.]+$') { throw 'Invalid machine identity.' }
    $worker = Join-Path $PSScriptRoot 'Machine.ps1'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action {1}' -f $worker,$Action
    if ($Identity) { $arguments += ' -Identity ' + $Identity }
    $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -notin @(0,3010)) { throw "Elevated $Action failed or was cancelled (exit $($process.ExitCode))." }
    return $process.ExitCode
}

function Install-WinGet {
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) { return }
    try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch { Write-Verbose $_ }
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) { return }
    Install-PackageProvider -Name NuGet -Scope CurrentUser -Force | Out-Null
    Install-Module -Name Microsoft.WinGet.Client -Scope CurrentUser -Repository PSGallery -Force
    Import-Module Microsoft.WinGet.Client
    Repair-WinGetPackageManager -Force -Latest
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { throw 'WinGet bootstrap did not expose winget.exe. Sign out/in and resume.' }
}

function Test-WinGetPackage($Id) {
    & winget.exe list --id $Id --exact --source winget --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }
    # APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND
    if ($LASTEXITCODE -eq -1978335212) { return $false }
    throw "WinGet inventory failed for $Id (exit $LASTEXITCODE)."
}

function Install-WinGetPackage($State, $Path, $Id) {
    if (-not $State.versions.ContainsKey($Id)) {
        $output = Invoke-Native winget.exe @('show','--id',$Id,'--exact','--source','winget','--versions','--accept-source-agreements','--disable-interactivity') -Capture
        $lines = @($output -split "`n")
        $after = $false; $version = $null
        foreach ($line in $lines) {
            if ($line.Trim() -match '^-{3,}$') { $after=$true; continue }
            if ($after -and $line.Trim() -match '^[0-9][0-9A-Za-z.+_-]*$') { $version=$line.Trim(); break }
        }
        if (-not $version) { throw "Unable to resolve a version for $Id; no unpinned install attempted." }
        $State.versions[$Id]=$version; Write-Json $Path $State
    }
    Invoke-Native winget.exe @('install','--id',$Id,'--exact','--version',$State.versions[$Id],'--source','winget','--silent','--accept-source-agreements','--accept-package-agreements','--disable-interactivity')
    if (-not (Test-WinGetPackage $Id)) { throw "$Id was not found after installation." }
}

function Save-WinGetInventory($State,$Path) {
    $inventory=Join-Path (Split-Path $Path) 'winget-inventory.json'
    Invoke-Native winget.exe @('export','--output',$inventory,'--include-versions','--accept-source-agreements','--disable-interactivity')
    $export=Read-Json $inventory
    $State['observedWindows']=@{}
    foreach ($source in $export.Sources) {
        foreach ($package in $source.Packages) {
            if (@($State.install | Where-Object { $_.kind -eq 'windows' -and $_.selected -and $_.id -eq $package.PackageIdentifier }).Count) {
                $State.observedWindows[$package.PackageIdentifier]=$package.Version
            }
        }
    }
    Write-Json $Path $State
}

function Save-FileBackup($State, $StatePath, $Target) {
    if (@($State.backups | Where-Object { $_.kind -eq 'file' -and $_.target -eq $Target }).Count) { return }
    $exists = Test-Path -LiteralPath $Target
    $copy = Join-Path (Split-Path $StatePath) ('backups\' + [guid]::NewGuid().ToString('N'))
    if ($exists) { [IO.Directory]::CreateDirectory((Split-Path $copy)) | Out-Null; Copy-Item -LiteralPath $Target -Destination $copy }
    $State.backups += @{kind='file'; target=$Target; existed=$exists; copy=$copy}
    Write-Json $StatePath $State
}

function Set-BackedRegistry($State, $StatePath, $Key, $Name, $Value, $Type='DWord') {
    if (-not @($State.backups | Where-Object { $_.kind -eq 'registry' -and $_.target -eq $Key -and $_.name -eq $Name }).Count) {
        $item = Get-Item -LiteralPath $Key -ErrorAction SilentlyContinue
        $exists = $item -and $Name -in $item.GetValueNames()
        $old = $null; $oldType = $Type
        if ($exists) { $old=$item.GetValue($Name); $oldType=$item.GetValueKind($Name).ToString() }
        $State.backups += @{kind='registry'; target=$Key; name=$Name; existed=[bool]$exists; value=$old; type=$oldType}
        Write-Json $StatePath $State
    }
    if (-not (Test-Path -LiteralPath $Key)) { New-Item -Path $Key -Force | Out-Null }
    New-ItemProperty -LiteralPath $Key -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Set-DesktopOption($State,$Path,$Id) {
    $cdm='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    switch ($Id) {
        'ads' {
            Set-BackedRegistry $State $Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
            foreach ($name in @('SilentInstalledAppsEnabled','PreInstalledAppsEnabled','OemPreInstalledAppsEnabled')) { Set-BackedRegistry $State $Path $cdm $name 0 }
        }
        'suggestions' {
            foreach ($name in @('SystemPaneSuggestionsEnabled','SoftLandingEnabled','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled')) { Set-BackedRegistry $State $Path $cdm $name 0 }
            Set-BackedRegistry $State $Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSyncProviderNotifications' 0
        }
        'widgets' {
            Set-BackedRegistry $State $Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
            if (-not @($State.backups | Where-Object kind -eq 'machine-widgets').Count) {
                $key=Get-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -ErrorAction SilentlyContinue
                $value='absent'
                if ($key -and 'AllowNewsAndInterests' -in $key.GetValueNames()) {
                    if ($key.GetValueKind('AllowNewsAndInterests') -ne 'DWord') { throw 'Unexpected Widgets policy type; refusing to overwrite it.' }
                    $value=[string]$key.GetValue('AllowNewsAndInterests')
                }
                $State.backups += @{kind='machine-widgets'; value=$value}; Write-Json $Path $State
            }
            [void](Invoke-Machine WidgetsDisable)
        }
        'search-web' { Set-BackedRegistry $State $Path 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1 }
    }
}

function Initialize-ShellApi {
    if ('PerfectWin11.AppBar' -as [type]) { return }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace PerfectWin11 {
 public static class AppBar {
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int l,t,r,b; }
  [StructLayout(LayoutKind.Sequential)] struct DATA { public uint cbSize; public IntPtr hWnd; public uint callback; public uint edge; public RECT rect; public IntPtr param; }
  [DllImport("shell32.dll")] static extern UIntPtr SHAppBarMessage(uint msg, ref DATA data);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
  public static uint Get() { var d=new DATA(); d.cbSize=(uint)Marshal.SizeOf(d); d.hWnd=FindWindow("Shell_TrayWnd",null); return SHAppBarMessage(4,ref d).ToUInt32(); }
  public static void Set(uint state) { var d=new DATA(); d.cbSize=(uint)Marshal.SizeOf(d); d.hWnd=FindWindow("Shell_TrayWnd",null); if(d.hWnd==IntPtr.Zero) throw new Exception("Explorer taskbar unavailable"); d.param=(IntPtr)state; SHAppBarMessage(10,ref d); }
 }
}
'@
}

function Set-Taskbar($State,$Path) {
    Initialize-ShellApi
    $old = [PerfectWin11.AppBar]::Get()
    if (-not @($State.backups | Where-Object kind -eq 'taskbar').Count) {
        $State.backups += @{kind='taskbar'; value=$old}; Write-Json $Path $State
    }
    [PerfectWin11.AppBar]::Set($old -bor 1)
    if (([PerfectWin11.AppBar]::Get() -band 1) -eq 0) { throw 'Taskbar auto-hide verification failed.' }
}

function ConvertFrom-Jsonc([string]$Text) {
    # Tokenize strings first, so URLs/comment-like text inside strings remain intact.
    $pattern='"(?:\\.|[^"\\])*"|/\*[\s\S]*?\*/|//[^\r\n]*'
    $clean=[regex]::Replace($Text,$pattern,[Text.RegularExpressions.MatchEvaluator]{ param($m) if ($m.Value.StartsWith('"')) { $m.Value } else { ' ' } })
    $clean=[regex]::Replace($clean,'"(?:\\.|[^"\\])*"|,\s*(?=[}\]])',[Text.RegularExpressions.MatchEvaluator]{ param($m) if ($m.Value.StartsWith('"')) { $m.Value } else { '' } })
    ConvertTo-Map ($clean | ConvertFrom-Json)
}

function Set-Terminal($State,$Path) {
    $packaged=Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
    $unpackaged=Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'
    $target=if (Test-Path $unpackaged) { $unpackaged } else { $packaged }
    $settings=if (Test-Path $target) { ConvertFrom-Jsonc (Get-Content $target -Raw) } else { @{} }
    Save-FileBackup $State $Path $target
    $guid='{c13a5a55-19a1-4e9f-8424-8120db444124}'
    if (-not $settings.ContainsKey('profiles')) { $settings.profiles=@{list=@()} }
    if ($settings.profiles -is [array]) { $settings.profiles=@{list=@($settings.profiles)} }
    if (-not $settings.profiles.ContainsKey('list')) { $settings.profiles.list=@() }
    $profile=@($settings.profiles.list | Where-Object { $_.ContainsKey('guid') -and $_.guid -eq $guid })
    if ($profile.Count) { $entry=$profile[0] } else { $entry=@{guid=$guid; name='Ubuntu (Perfect Win11)'}; $settings.profiles.list += $entry }
    $entry.commandline='wsl.exe -d "' + $State.distro + '"'
    $entry.startingDirectory='\\wsl.localhost\' + $State.distro + '\home\' + $State.linuxUser
    $entry.hidden=$false
    $settings.defaultProfile=$guid
    Write-Json $target $settings
}

function Find-PowerToys {
    foreach ($path in @("$env:LOCALAPPDATA\PowerToys\PowerToys.exe","$env:ProgramFiles\PowerToys\PowerToys.exe")) { if (Test-Path $path) { return $path } }
    throw 'PowerToys executable not found.'
}

function Set-PowerToys($State,$Path) {
    $exe=Find-PowerToys
    $target=Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\settings.json'
    if (-not (Test-Path $target)) {
        Start-Process -FilePath $exe
        for ($i=0; $i -lt 20 -and -not (Test-Path $target); $i++) { Start-Sleep -Milliseconds 500 }
    }
    if (-not (Test-Path $target)) { throw 'Open PowerToys once to initialize settings, then resume.' }
    # Stop only this user's runner; preserve all unrelated configuration properties.
    Get-Process PowerToys -ErrorAction SilentlyContinue | Where-Object SessionId -EQ (Get-Process -Id $PID).SessionId | Stop-Process
    Start-Sleep -Milliseconds 500
    $settings=Read-Json $target
    if (-not $settings.ContainsKey('enabled') -or -not $settings.enabled.ContainsKey('CmdPal')) { throw 'Unrecognized PowerToys settings: enable Command Palette once in Settings and resume.' }
    Save-FileBackup $State $Path $target
    $settings.startup=$true; $settings.enabled['CmdPal']=$true
    Write-Json $target $settings
    Set-BackedRegistry $State $Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'PerfectWin11.PowerToys' ('"'+$exe+'"') 'String'
    Start-Process -FilePath $exe
    for ($i=0; $i -lt 40; $i++) {
        try {
            $event=[Threading.EventWaitHandle]::OpenExisting('Local\PowerToysCmdPal-ShowEvent-62336fcd-8611-4023-9b30-091a6af4cc5a')
            $event.Dispose(); return
        } catch [Threading.WaitHandleCannotBeOpenedException] { Start-Sleep -Milliseconds 500 }
    }
    throw 'Command Palette did not expose its show event. Open PowerToys, enable Command Palette, and resume.'
}

function Install-WinTap($State,$Path) {
    $ahk=$null
    foreach ($candidate in @("$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe","$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe")) { if (Test-Path $candidate) { $ahk=$candidate; break } }
    if (-not $ahk) { throw 'AutoHotkey v2 executable not found.' }
    $target=Join-Path (Split-Path $Path) 'WinTap.ahk'
    Save-FileBackup $State $Path $target
    Copy-Item -LiteralPath "$PSScriptRoot\..\assets\WinTap.ahk" -Destination $target -Force
    Set-BackedRegistry $State $Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'PerfectWin11.WinTap' ('"'+$ahk+'" "'+$target+'"') 'String'
    Start-Process -FilePath $ahk -ArgumentList ('"'+$target+'"')
}

Export-ModuleMember -Function *
