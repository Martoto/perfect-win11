Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot\Core.psm1"
Import-Module "$PSScriptRoot\Windows.psm1"

function Get-SettingRegistryTargets($Id) {
    $cdm='HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $advanced='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $run='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    switch ($Id) {
        'ads' {
            @{target='HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; name='Enabled'}
            foreach ($name in @('SilentInstalledAppsEnabled','PreInstalledAppsEnabled','OemPreInstalledAppsEnabled')) { @{target=$cdm; name=$name} }
        }
        'suggestions' {
            foreach ($name in @('SystemPaneSuggestionsEnabled','SoftLandingEnabled','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled')) { @{target=$cdm; name=$name} }
            @{target=$advanced; name='ShowSyncProviderNotifications'}
        }
        'widgets' { @{target=$advanced; name='TaskbarDa'} }
        'search-web' { @{target='HKCU:\Software\Policies\Microsoft\Windows\Explorer'; name='DisableSearchBoxSuggestions'} }
        'win-tap' { @{target=$run; name='PerfectWin11.WinTap'} }
        'powertoys-startup' { @{target=$run; name='PerfectWin11.PowerToys'} }
    }
}

function Get-RegistryRestoreRecords($State,$Id) {
    $records=@()
    foreach ($item in Get-SettingRegistryTargets $Id) {
        $found=@($State.backups | Where-Object { $_.kind -eq 'registry' -and $_.target -eq $item.target -and $_.name -eq $item.name })
        if ($found.Count -ne 1) { throw "Missing original registry backup for $Id / $($item.name). Restore it manually before retrying." }
        $records += $found[0]
    }
    return ,$records
}

function Restore-RegistryRecord($Record) {
    if ($Record.existed) {
        if (-not (Test-Path -LiteralPath $Record.target)) { New-Item -Path $Record.target -Force | Out-Null }
        New-ItemProperty -LiteralPath $Record.target -Name $Record.name -PropertyType $Record.type -Value $Record.value -Force | Out-Null
    } elseif (Test-Path -LiteralPath $Record.target) {
        $key=Get-Item -LiteralPath $Record.target
        if ($Record.name -in $key.GetValueNames()) { Remove-ItemProperty -LiteralPath $Record.target -Name $Record.name -ErrorAction Stop }
    }
}

function Get-SettingJsonTarget($State,$Id) {
    if ($Id -eq 'powertoys-startup') { return @{target=(Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\settings.json'); name='startup'} }
    if ($Id -eq 'terminal-default') {
        # Prefer the file originally modified, even if another Terminal install appears later.
        $backup=@($State.backups | Where-Object { $_.kind -in @('file','json-property') -and $_.target -match '(Windows Terminal|Microsoft.WindowsTerminal_8wekyb3d8bbwe).*settings\.json$' })
        if ($backup.Count) { $target=$backup[0].target } else {
            $unpackaged=Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'
            $target=if (Test-Path $unpackaged) {$unpackaged} else {Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'}
        }
        return @{target=$target; name='defaultProfile'}
    }
    throw "No JSON setting for $Id."
}

function Get-JsonRestoreRecord($State,$Target,$Name) {
    $property=@($State.backups | Where-Object { $_.kind -eq 'json-property' -and $_.target -eq $Target -and $_.name -eq $Name })
    if ($property.Count) { return $property[0] }
    $file=@($State.backups | Where-Object { $_.kind -eq 'file' -and $_.target -eq $Target })
    if ($file.Count -ne 1) { throw "Missing original JSON backup: $Target / $Name" }
    $original=@{}
    if ($file[0].existed) {
        if (-not (Test-Path -LiteralPath $file[0].copy)) { throw "Original backup file is missing: $($file[0].copy)" }
        $original=ConvertFrom-Jsonc (Get-Content -LiteralPath $file[0].copy -Raw)
    }
    @{kind='json-property'; target=$Target; name=$Name; existed=$original.ContainsKey($Name); value=$(if ($original.ContainsKey($Name)) {$original[$Name]} else {$null})}
}

function Save-JsonPropertyBackup($State,$Path,$Target,$Name,$Current) {
    if (@($State.backups | Where-Object { $_.kind -eq 'json-property' -and $_.target -eq $Target -and $_.name -eq $Name }).Count) { return }
    if (@($State.backups | Where-Object { $_.kind -eq 'file' -and $_.target -eq $Target }).Count) { $record=Get-JsonRestoreRecord $State $Target $Name }
    else { $record=@{kind='json-property'; target=$Target; name=$Name; existed=$Current.ContainsKey($Name); value=$(if ($Current.ContainsKey($Name)) {$Current[$Name]} else {$null})} }
    $State.backups += $record; Write-Json $Path $State
}

function Set-JsonSetting($State,$Path,$Id,[bool]$Enabled) {
    $item=Get-SettingJsonTarget $State $Id
    if (-not (Test-Path -LiteralPath $item.target)) { throw "Settings file missing: $($item.target). Open the application once and retry." }
    $current=ConvertFrom-Jsonc (Get-Content -LiteralPath $item.target -Raw)
    if ($Enabled) {
        Save-JsonPropertyBackup $State $Path $item.target $item.name $current
        $current[$item.name]=if ($Id -eq 'terminal-default') {'{c13a5a55-19a1-4e9f-8424-8120db444124}'} else {$true}
    } else {
        $original=Get-JsonRestoreRecord $State $item.target $item.name
        if ($original.existed) { $current[$item.name]=$original.value } else { $current.Remove($item.name) }
    }
    Write-Json $item.target $current
}

function Stop-ManagedWinTap($Path) {
    $target=Join-Path (Split-Path $Path) 'WinTap.ahk'
    $pattern='(?:^|\s)"'+[regex]::Escape($target)+'"(?:\s|$)'
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'") ) {
        if ($process.SessionId -eq (Get-Process -Id $PID).SessionId -and $process.CommandLine -match $pattern) { Stop-Process -Id $process.ProcessId -ErrorAction Stop }
    }
}

function Stop-UserPowerToys {
    Get-Process PowerToys -ErrorAction SilentlyContinue | Where-Object SessionId -EQ (Get-Process -Id $PID).SessionId | Stop-Process -ErrorAction Stop
    Start-Sleep -Milliseconds 500
}

function Set-ManagedDesktopSetting($State,$Path,$Id,[bool]$Enabled) {
    if ($Id -notin @(Get-SettingsCatalog | ForEach-Object { $_.id })) { throw "Unknown desktop setting: $Id" }
    # Validate every required original before restoring anything in this setting.
    $records=@()
    if (-not $Enabled) {
        $records=Get-RegistryRestoreRecords $State $Id
        if ($Id -in @('terminal-default','powertoys-startup')) {
            $json=Get-SettingJsonTarget $State $Id
            [void](Get-JsonRestoreRecord $State $json.target $json.name)
            if (-not (Test-Path -LiteralPath $json.target)) { throw "Settings file missing: $($json.target)" }
            [void](ConvertFrom-Jsonc (Get-Content -LiteralPath $json.target -Raw))
        }
        if ($Id -in @('taskbar','widgets')) {
            $kind=if ($Id -eq 'taskbar') {'taskbar'} else {'machine-widgets'}
            $original=@($State.backups | Where-Object kind -eq $kind)
            if ($original.Count -ne 1) { throw "Missing original backup for $Id." }
        }
    }
    switch ($Id) {
        'taskbar' {
            if ($Enabled) { Set-Taskbar $State $Path }
            else { Initialize-ShellApi; [PerfectWin11.AppBar]::Set(([PerfectWin11.AppBar]::Get() -band 0xfffffffe) -bor ([uint32]$original[0].value -band 1)) }
        }
        'terminal-default' { Set-JsonSetting $State $Path $Id $Enabled }
        'powertoys-startup' {
            $exe=Find-PowerToys
            Stop-UserPowerToys
            try {
                Set-JsonSetting $State $Path $Id $Enabled
                if ($Enabled) { Set-BackedRegistry $State $Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'PerfectWin11.PowerToys' ('"'+$exe+'"') 'String' }
                else { foreach ($record in $records) { Restore-RegistryRecord $record } }
            } finally { Start-Process -FilePath $exe }
        }
        'win-tap' {
            if ($Enabled) {
                Install-WinGet
                if (-not (Test-WinGetPackage 'AutoHotkey.AutoHotkey')) { Install-WinGetPackage $State $Path 'AutoHotkey.AutoHotkey' }
                Install-WinTap $State $Path
            } else {
                Stop-ManagedWinTap $Path
                foreach ($record in $records) { Restore-RegistryRecord $record }
            }
        }
        default {
            if ($Enabled) { Set-DesktopOption $State $Path $Id }
            else {
                if ($Id -eq 'widgets') { [void](Invoke-Machine WidgetsRestore $original[0].value) }
                foreach ($record in $records) { Restore-RegistryRecord $record }
            }
        }
    }
    $State.appliedSettings[$Id]=$Enabled
    Write-Json $Path $State
}

function New-Reconfiguration($State,$Desired) {
    if (-not $State.setupComplete) { throw 'Finish the existing setup with -Resume before reconfiguring.' }
    if ($State.reconfiguration) { throw 'A reconfiguration is unfinished. Use -Resume.' }
    foreach ($id in $Desired.Keys) { if ($id -notin @(Get-SettingsCatalog | ForEach-Object { $_.id })) { throw "Unknown desktop setting: $id" } }
    $actions=@()
    foreach ($item in Get-SettingsCatalog) {
        if (-not $Desired.ContainsKey($item.id) -or $Desired[$item.id] -isnot [bool]) { throw "Invalid choice: $($item.id)" }
        if ($Desired[$item.id] -ne $State.appliedSettings[$item.id]) {
            $actions += @{setting=$item.id; enabled=$Desired[$item.id]; status='pending'; error=$null}
        }
    }
    return @{id=[guid]::NewGuid().ToString('N'); created=(Get-Date).ToString('o'); actions=$actions; targetSettings=$Desired.Clone()}
}

function Invoke-InitialDesktopSettings($State,$Path,[bool]$PowerToysReady=$true,[switch]$TerminalOnly) {
    foreach ($setting in Get-SettingsCatalog) {
        $id=$setting.id
        if (-not $State.settings[$id]) { continue }
        if ($TerminalOnly -ne ($id -eq 'terminal-default')) { continue }
        if ($id -in @('win-tap','powertoys-startup') -and -not $PowerToysReady) { continue }
        if ($id -eq 'win-tap') {
            [void](Invoke-Step $State $Path "desktop:$id" { Set-ManagedDesktopSetting $State $Path $id $true } { $State.appliedSettings[$id] -and (Test-WinTapInstalled $Path) })
        } else { [void](Invoke-Step $State $Path "desktop:$id" { Set-ManagedDesktopSetting $State $Path $id $true }) }
    }
}

function Invoke-Reconfiguration($State,$Path) {
    if (-not $State.reconfiguration) { throw 'No pending reconfiguration.' }
    $batch=$State.reconfiguration
    foreach ($action in $batch.actions) {
        $title=(Get-SettingsCatalog | Where-Object id -eq $action.setting).title
        if ($action.status -eq 'done') { Write-Host "[SKIPPED] $title"; continue }
        Write-Host "[RUNNING] $title ($(if ($action.enabled) {'apply'} else {'restore original'}))"
        $action.status='running'; $action.error=$null; Write-Json $Path $State
        try {
            Set-ManagedDesktopSetting $State $Path $action.setting $action.enabled
            $action.status='done'; Write-Host "[DONE] $title"
        } catch { $action.status='failed'; $action.error=$_.Exception.Message; Write-Warning "$title failed: $($action.error)" }
        Write-Json $Path $State
    }
    if (@($batch.actions | Where-Object status -ne 'done').Count) { return $false }
    $State.settings=$batch.targetSettings.Clone()
    foreach ($item in $State.remove) { if ($item.kind -eq 'setting') { $item.selected=$State.settings[$item.id] } }
    $batch['completed']=(Get-Date).ToString('o')
    $State.history += $batch; $State.reconfiguration=$null
    Write-Json $Path $State
    return $true
}

Export-ModuleMember -Function *
