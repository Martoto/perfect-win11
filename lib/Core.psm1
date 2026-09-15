Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-Map($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value.GetType().IsValueType) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $map = @{}; foreach ($key in $Value.Keys) { $map[$key] = ConvertTo-Map $Value[$key] }; return $map
    }
    if ($Value -is [pscustomobject]) {
        $map = @{}; foreach ($p in $Value.PSObject.Properties) { $map[$p.Name] = ConvertTo-Map $p.Value }; return $map
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return ,@($Value | ForEach-Object { ConvertTo-Map $_ })
    }
    return $Value
}

function Read-Json($Path) { ConvertTo-Map (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }

function Write-Json($Path, $Value) {
    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 50), (New-Object Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, "$Path.previous") }
    else { [IO.File]::Move($temp, $Path) }
}

function Assert-Manifest($Manifest) {
    if ($Manifest -isnot [System.Collections.IDictionary]) { throw 'Manifest must be a JSON object.' }
    foreach ($key in $Manifest.Keys) {
        if ($key -cnotin @('schemaVersion','windows','wsl')) { throw "Unsupported manifest field: $key" }
    }
    if (-not $Manifest.Contains('schemaVersion') -or $Manifest.schemaVersion -isnot [int] -or $Manifest.schemaVersion -ne 1) {
        throw 'schemaVersion must be the integer 1.'
    }
    foreach ($kind in @('windows','wsl')) {
        if (-not $Manifest.Contains($kind) -or $Manifest[$kind] -isnot [array]) { throw "$kind must be an array." }
        if ($Manifest[$kind].Count -gt 200) { throw 'Maximum 200 entries per package list.' }
        foreach ($id in $Manifest[$kind]) {
            $pattern = if ($kind -eq 'windows') { '^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)+$' } else { '^[a-z0-9][a-z0-9+.-]+$' }
            if ($id -isnot [string] -or $id.Length -gt 128 -or $id -match '[\r\n]' -or $id -cnotmatch $pattern) { throw "Invalid $kind package ID: $id" }
        }
    }
}

function Read-Manifest([string]$Location) {
    if ($Location -match '^https://') {
        $response = Invoke-WebRequest -Uri $Location -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 30
        $raw = $response.Content
    } elseif ($Location -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') { throw 'Only HTTPS URLs or local files are accepted.' }
    else { $raw = Get-Content -LiteralPath $Location -Raw }
    if ($raw.Length -gt 1048576) { throw 'Manifest exceeds 1 MiB.' }
    $manifest = ConvertTo-Map ($raw | ConvertFrom-Json)
    Assert-Manifest $manifest
    return $manifest
}

function Get-InstallCatalog {
    $items = @(
        @{ id='Microsoft.PowerToys'; kind='windows'; required=$true; selected=$true },
        @{ id='Microsoft.WindowsTerminal'; kind='windows'; required=$true; selected=$true },
        @{ id='AutoHotkey.AutoHotkey'; kind='windows'; required=$false; selected=$false },
        @{ id='Microsoft.VisualStudioCode'; kind='windows'; required=$false; selected=$true },
        @{ id='Microsoft.PowerShell'; kind='windows'; required=$false; selected=$true }
    )
    foreach ($id in @('git','gh','neovim','tmux','ripgrep','fd-find','fzf','bat','jq','btop','zoxide','build-essential','curl','ca-certificates','gnupg','unzip','zip','pkg-config','libssl-dev','zlib1g-dev','libbz2-dev','libreadline-dev','libsqlite3-dev','libffi-dev','liblzma-dev','libyaml-dev','libgdbm-dev','libncurses-dev','uuid-dev','tk-dev')) {
        $items += @{ id=$id; kind='wsl'; required=$false; selected=$true }
    }
    foreach ($id in @('mise','starship','runtimes','docker')) {
        $items += @{ id=$id; kind='feature'; required=$false; selected=$true }
    }
    return $items
}

function Merge-InstallCatalog($Catalog, $Manifest) {
    Assert-Manifest $Manifest
    $result = New-Object Collections.ArrayList
    $seen = @{}
    foreach ($item in $Catalog) {
        $key = "$($item.kind):$($item.id)".ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) { $seen[$key]=$true; [void]$result.Add($item.Clone()) }
    }
    foreach ($kind in @('windows','wsl')) {
        foreach ($id in $Manifest[$kind]) {
            $key = "${kind}:$id".ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key]=$true; [void]$result.Add(@{id=$id; kind=$kind; required=$false; selected=$true})
            }
        }
    }
    return ,@($result)
}

function Get-RemovalCatalog {
    # Explicit identities only; never wildcard matching or an externally supplied removal list.
    @(
        @{id='Clipchamp.Clipchamp'; kind='appx'; selected=$true},
        @{id='Microsoft.BingNews'; kind='appx'; selected=$true},
        @{id='Microsoft.BingWeather'; kind='appx'; selected=$true},
        @{id='Microsoft.MicrosoftSolitaireCollection'; kind='appx'; selected=$true},
        @{id='Microsoft.MicrosoftOfficeHub'; kind='appx'; selected=$true},
        @{id='Microsoft.Getstarted'; kind='appx'; selected=$true},
        @{id='Microsoft.WindowsFeedbackHub'; kind='appx'; selected=$true},
        @{id='Microsoft.OneDrive'; kind='desktop'; selected=$false},
        @{id='Microsoft.GamingApp'; kind='appx'; selected=$false},
        @{id='Microsoft.XboxGamingOverlay'; kind='appx'; selected=$false},
        @{id='MSTeams'; kind='appx'; selected=$false},
        @{id='MicrosoftTeams'; kind='appx'; selected=$false},
        @{id='Microsoft.OutlookForWindows'; kind='appx'; selected=$false},
        @{id='Microsoft.Copilot'; kind='appx'; selected=$false},
        @{id='ads'; kind='setting'; selected=$true},
        @{id='suggestions'; kind='setting'; selected=$true},
        @{id='widgets'; kind='setting'; selected=$true},
        @{id='search-web'; kind='setting'; selected=$true}
    )
}

function Select-Checklist($Title, $Items) {
    while ($true) {
        Write-Host "`n$Title (comma-separated numbers toggle; Enter accepts)"
        for ($i=0; $i -lt $Items.Count; $i++) {
            $mark = if ($Items[$i].selected) { 'x' } else { ' ' }
            $required = if ($Items[$i].ContainsKey('required') -and $Items[$i].required) { ' [required]' } else { '' }
            Write-Host ('{0,3}. [{1}] {2}: {3}{4}' -f ($i+1),$mark,$Items[$i].kind,$Items[$i].id,$required)
        }
        $answer = Read-Host 'Selection'
        if ([string]::IsNullOrWhiteSpace($answer)) { break }
        if ($answer -notmatch '^\s*\d+(\s*,\s*\d+)*\s*$') { Write-Warning 'Enter numbers separated by commas.'; continue }
        foreach ($number in ($answer -split ',')) {
            $n = 0
            if (-not [int]::TryParse($number.Trim(), [ref]$n) -or $n -lt 1 -or $n -gt $Items.Count) { Write-Warning "Invalid number: $number"; continue }
            $item = $Items[$n-1]
            if ($item.ContainsKey('required') -and $item.required) { continue }
            $item.selected = -not $item.selected
        }
    }
    return ,@($Items)
}

function New-SetupState($Manifest, $Install, $Remove, $Sid) {
    $state=@{ schemaVersion=2; ownerSid=$Sid; created=(Get-Date).ToUniversalTime().ToString('o'); manifest=$Manifest;
        install=@($Install); remove=@($Remove); versions=@{}; steps=@{}; backups=@(); removals=@();
        distro='Ubuntu-24.04'; reuseApproved=$false; linuxUser=$null; linux=@{}; rebootBoot=$null;
        settings=@{}; appliedSettings=@{}; setupComplete=$false; reconfiguration=$null; history=@() }
    foreach ($item in Get-SettingsCatalog) { $state.settings[$item.id]=$true; $state.appliedSettings[$item.id]=$false }
    foreach ($item in $Remove) { if ($item.kind -eq 'setting') { $state.settings[$item.id]=[bool]$item.selected } }
    return $state
}

function Read-SetupState($Path, $Sid) {
    $state = Read-Json $Path
    if ($state.schemaVersion -notin @(1,2) -or $state.ownerSid -ne $Sid) { throw 'State version or initiating user does not match.' }
    Assert-Manifest $state.manifest
    $selectedManifest = @{schemaVersion=1; windows=@($state.install | Where-Object kind -eq 'windows' | ForEach-Object { $_.id }); wsl=@($state.install | Where-Object kind -eq 'wsl' | ForEach-Object { $_.id })}
    Assert-Manifest $selectedManifest
    if ($state.distro -notmatch '^[A-Za-z0-9._-]+$') { throw 'Invalid saved distribution name.' }
    if ($state.linuxUser -and ($state.linuxUser -eq 'root' -or $state.linuxUser -notmatch '^[a-z_][a-z0-9_-]*$')) { throw 'Invalid saved Linux user.' }
    foreach ($item in $state.install) {
        if ($item.kind -notin @('windows','wsl','feature') -or ($item.kind -eq 'feature' -and $item.id -notin @('mise','starship','runtimes','docker'))) { throw 'Invalid saved installation feature.' }
    }
    foreach ($item in $state.remove) {
        if (-not @(Get-RemovalCatalog | Where-Object { $_.id -ceq $item.id -and $_.kind -ceq $item.kind }).Count) { throw 'Unknown removal in saved state.' }
    }
    return (ConvertTo-SetupV2 $state)
}

function Get-SettingsCatalog {
    @(
        @{id='taskbar'; title='Auto-hide the taskbar'; group='Desktop'; description='Make more room for your work. Move the pointer to the screen edge to reveal the taskbar.'},
        @{id='win-tap'; title='Tap Win to open Command Palette'; group='Desktop'; description='A short Win tap opens Command Palette; Win shortcuts stay native. Requires AutoHotkey and running PowerToys.'},
        @{id='powertoys-startup'; title='Start PowerToys when I sign in'; group='Desktop'; description='Makes Command Palette available after login. Independent of the Win-tap toggle.'},
        @{id='terminal-default'; title='Open Ubuntu by default in Terminal'; group='Desktop'; description='Changes the default profile only. Your other profiles remain available.'},
        @{id='ads'; title='Disable ads and promotional installs'; group='Distractions'; description='Disable advertising personalization and suggested app installs for this user.'},
        @{id='suggestions'; title='Disable tips and suggestions'; group='Distractions'; description='Reduce Windows tips, Start suggestions and Explorer promotional notifications.'},
        @{id='widgets'; title='Disable Widgets'; group='Distractions'; description='Hide the taskbar entry and apply the machine Widgets policy (requests UAC).'},
        @{id='search-web'; title='Disable web results in Search'; group='Distractions'; description='Apply the Windows Search web-suggestions preference. Sign out/in to see policy changes.'}
    )
}

function Test-StepDone($State,$Name) {
    return $State.steps.ContainsKey($Name) -and $State.steps[$Name].status -in @('done','satisfied')
}

function Test-SetupComplete($State) {
    if ($State.rebootBoot) { return $false }
    $expected=@('winget','windows-inventory','powertoys-settings','wsl-features','wsl-update','wsl-user','wsl-systemd','linux-install','linux-verify','terminal-profile')
    foreach ($item in $State.install) { if ($item.kind -eq 'windows' -and $item.selected) { $expected += 'install:'+$item.id } }
    foreach ($item in $State.remove) {
        if ($item.selected -and ($State.schemaVersion -eq 1 -or $item.kind -ne 'setting')) { $expected += "remove:$($item.kind):$($item.id)" }
    }
    if (@($State.install | Where-Object { $_.id -eq 'Microsoft.VisualStudioCode' -and $_.selected }).Count) { $expected += 'vscode-wsl' }
    if ($State.schemaVersion -eq 1) { $expected += @('taskbar','win-tap') }
    else { foreach ($id in $State.settings.Keys) { if ($State.settings[$id] -and -not $State.appliedSettings[$id]) { return $false } } }
    foreach ($name in $expected) { if (-not (Test-StepDone $State $name)) { return $false } }
    return -not @($State.steps.Values | Where-Object { $_.status -in @('running','failed') }).Count
}

function ConvertTo-SetupV2($State) {
    if ($State.schemaVersion -eq 1) {
        $complete=Test-SetupComplete $State
        $State.settings=@{}; $State.appliedSettings=@{}
        $legacy=@{taskbar='taskbar'; 'win-tap'='win-tap'; 'powertoys-startup'='powertoys-settings'; 'terminal-default'='terminal-profile'}
        foreach ($item in Get-SettingsCatalog) {
            $id=$item.id; $desired=$true
            if (-not $legacy.ContainsKey($id)) {
                $choice=@($State.remove | Where-Object { $_.kind -eq 'setting' -and $_.id -eq $id })
                $desired=$choice.Count -gt 0 -and $choice[0].selected
                $legacy[$id]="remove:setting:$id"
            }
            $State.settings[$id]=[bool]$desired
            $State.appliedSettings[$id]=[bool]($desired -and (Test-StepDone $State $legacy[$id]))
            if ($State.appliedSettings[$id]) { $State.steps["desktop:$id"]=@{status='done'; error=$null; migrated=$true} }
        }
        $State.setupComplete=$complete; $State.reconfiguration=$null; $State.history=@(); $State.schemaVersion=2
    }
    foreach ($field in @('settings','appliedSettings')) {
        if (-not $State.ContainsKey($field) -or $State[$field] -isnot [Collections.IDictionary]) { throw "Invalid saved $field." }
        $ids=@(Get-SettingsCatalog | ForEach-Object { $_.id })
        foreach ($id in $State[$field].Keys) { if ($id -notin $ids) { throw "Unknown saved setting: $id" } }
        foreach ($id in $ids) { if (-not $State[$field].ContainsKey($id) -or $State[$field][$id] -isnot [bool]) { throw "Invalid saved setting: $id" } }
    }
    if (-not $State.ContainsKey('reconfiguration') -or -not $State.ContainsKey('history') -or -not $State.ContainsKey('setupComplete')) { throw 'Incomplete settings state.' }
    if ($State.setupComplete -isnot [bool] -or $State.history -isnot [array]) { throw 'Invalid settings history or completion flag.' }
    if ($State.reconfiguration) {
        $seen=@{}
        foreach ($action in $State.reconfiguration.actions) {
            if ($action.setting -notin @(Get-SettingsCatalog | ForEach-Object { $_.id }) -or $action.enabled -isnot [bool]) { throw 'Invalid reconfiguration action.' }
            if ($action.status -notin @('pending','running','failed','done') -or $seen.ContainsKey($action.setting)) { throw 'Invalid or duplicate reconfiguration action.' }
            $seen[$action.setting]=$true
        }
        foreach ($item in Get-SettingsCatalog) {
            if (-not $State.reconfiguration.targetSettings.ContainsKey($item.id) -or $State.reconfiguration.targetSettings[$item.id] -isnot [bool]) { throw 'Invalid reconfiguration target settings.' }
        }
    }
    return $State
}

function Invoke-Step($State, $Path, [string]$Name, [scriptblock]$Action, [scriptblock]$Satisfied) {
    if (-not $Satisfied -and $State.steps.ContainsKey($Name) -and $State.steps[$Name].status -in @('done','satisfied')) { Write-Host "[SKIPPED] $Name"; return $true }
    Write-Host "[RUNNING] $Name"
    $State.steps[$Name] = @{status='running'; at=(Get-Date).ToString('o'); error=$null}
    Write-Json $Path $State
    try {
        if ($Satisfied -and (& $Satisfied)) {
            $State.steps[$Name] = @{status='satisfied'; at=(Get-Date).ToString('o'); error=$null}
            Write-Json $Path $State; Write-Host "[SKIPPED] $Name (already satisfied)"; return $true
        }
        & $Action | Out-Host
        $State.steps[$Name] = @{status='done'; at=(Get-Date).ToString('o'); error=$null}
        Write-Json $Path $State; Write-Host "[DONE] $Name"; return $true
    } catch {
        $State.steps[$Name] = @{status='failed'; at=(Get-Date).ToString('o'); error=$_.Exception.Message}
        Write-Json $Path $State
        Write-Warning "$Name failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-Native([string]$File, [string[]]$Arguments, [switch]$Capture) {
    $output = & $File @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "$File exit ${code}: $($output -join [Environment]::NewLine)" }
    if ($Capture) { return ($output -join "`n") }
    $output | Out-Host
}

Export-ModuleMember -Function *
