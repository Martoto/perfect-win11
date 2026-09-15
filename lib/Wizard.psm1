Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module "$PSScriptRoot\Core.psm1"

function Get-BuildPackages {
    @('build-essential','pkg-config','libssl-dev','zlib1g-dev','libbz2-dev','libreadline-dev','libsqlite3-dev','libffi-dev','liblzma-dev','libyaml-dev','libgdbm-dev','libncurses-dev','uuid-dev','tk-dev')
}

function Get-ChoiceInfo($Id,$Kind) {
    $names=@{
        'Microsoft.PowerToys'='PowerToys'; 'Microsoft.WindowsTerminal'='Windows Terminal'; 'AutoHotkey.AutoHotkey'='AutoHotkey v2';
        'Microsoft.VisualStudioCode'='Visual Studio Code + WSL extension'; 'Microsoft.PowerShell'='PowerShell 7';
        'Clipchamp.Clipchamp'='Clipchamp'; 'Microsoft.BingNews'='Microsoft News'; 'Microsoft.BingWeather'='Weather';
        'Microsoft.MicrosoftSolitaireCollection'='Solitaire Collection'; 'Microsoft.MicrosoftOfficeHub'='Microsoft 365 promotional hub';
        'Microsoft.Getstarted'='Windows Tips'; 'Microsoft.WindowsFeedbackHub'='Feedback Hub'; 'Microsoft.OneDrive'='OneDrive';
        'Microsoft.GamingApp'='Xbox app'; 'Microsoft.XboxGamingOverlay'='Xbox Game Bar'; 'MSTeams'='Microsoft Teams';
        'MicrosoftTeams'='Microsoft Teams (legacy)'; 'Microsoft.OutlookForWindows'='Outlook for Windows'; 'Microsoft.Copilot'='Copilot';
        git='Git'; gh='GitHub CLI'; neovim='Neovim'; tmux='tmux'; ripgrep='ripgrep'; 'fd-find'='fd'; fzf='fzf'; bat='bat'; jq='jq'; btop='btop'; zoxide='zoxide';
        mise='mise version manager'; starship='Starship prompt'; runtimes='Node LTS, Python, Go, Rust and Ruby'; docker='Docker Engine, Buildx and Compose'
    }
    $descriptions=@{
        git='Track source code changes.'; gh='Work with GitHub from the Linux terminal.'; neovim='Edit code in the terminal.';
        tmux='Keep multiple terminal sessions organized.'; ripgrep='Search file contents quickly.'; 'fd-find'='Find files by name.';
        fzf='Choose files and history entries with fuzzy search.'; bat='Read files with syntax highlighting.'; jq='Inspect and transform JSON.';
        btop='Monitor CPU, memory and processes.'; zoxide='Jump to frequently used directories.';
        mise='Manage versioned developer tools. Required by runtimes and Starship.';
        starship='Use a configurable cross-shell prompt. Requires mise.';
        runtimes='Install all five runtimes through mise. Includes the libraries needed to build them.';
        docker='Install Docker from its Ubuntu repository. Docker-group membership grants Linux root-equivalent access.'
    }
    $title=if ($names.ContainsKey($Id)) { $names[$Id] } else { $Id }
    $description=if ($descriptions.ContainsKey($Id)) { $descriptions[$Id] } elseif ($Kind -eq 'remove') {
        'Remove this app for this user; Appx provisioning is also removed for future accounts. App data may not be recoverable.'
    } elseif ($Kind -eq 'windows') { 'Install this Windows application through WinGet.' } else { 'Install this Ubuntu package through APT.' }
    @{title=$title; description=$description}
}

function New-WizardModel($State,[switch]$Reconfigure) {
    $model=@{state=$State; reconfigure=[bool]$Reconfigure; choices=@(); screens=@('Desktop','Distractions'); page=0; focus=0;
        expanded=$false; message=''; cancelled=$false; finished=$false; confirmCancel=$false}
    foreach ($setting in Get-SettingsCatalog) {
        $model.choices += @{key='setting:'+$setting.id; id=$setting.id; kind='setting'; group=$setting.group; title=$setting.title;
            description=$setting.description; requested=[bool]$State.settings[$setting.id]; selected=[bool]$State.settings[$setting.id]; default=$true; required=$false; reasons=@(); build=$false}
    }
    if (-not $Reconfigure) {
        $model.screens += @('App removal','Windows apps','Linux tools')
        $defaults=Get-InstallCatalog
        foreach ($item in $State.remove) {
            if ($item.kind -eq 'setting') { continue }
            $info=Get-ChoiceInfo $item.id 'remove'
            $default=(Get-RemovalCatalog | Where-Object id -eq $item.id).selected
            $model.choices += @{key='remove:'+$item.id; id=$item.id; kind='remove'; group='App removal'; title=$info.title; description=$info.description;
                requested=[bool]$item.selected; selected=[bool]$item.selected; default=[bool]$default; required=$false; reasons=@(); build=$false}
        }
        foreach ($item in $State.install) {
            $info=Get-ChoiceInfo $item.id $item.kind
            $default=@($defaults | Where-Object { $_.id -eq $item.id -and $_.kind -eq $item.kind })
            $recommended=if ($default.Count) { [bool]$default[0].selected } else { $true }
            $requested=if ($item.ContainsKey('requested')) { [bool]$item.requested } else { [bool]$item.selected }
            if ($item.id -eq 'AutoHotkey.AutoHotkey' -and $item.id -in $State.manifest.windows) { $requested=$true; $recommended=$true }
            $model.choices += @{key=$item.kind+':'+$item.id; id=$item.id; kind=$item.kind; group=$(if ($item.kind -eq 'windows') {'Windows apps'} else {'Linux tools'});
                title=$info.title; description=$info.description; requested=$requested; selected=$requested; default=$recommended;
                required=($item.id -in @('Microsoft.PowerToys','Microsoft.WindowsTerminal')); reasons=@(); build=($item.kind -eq 'wsl' -and $item.id -in @(Get-BuildPackages))}
        }
    }
    $model.screens += 'Review'
    Resolve-WizardDependencies $model
    return $model
}

function Resolve-WizardDependencies($Model) {
    foreach ($choice in $Model.choices) { $choice.selected=$choice.requested -or $choice.required; $choice.reasons=@(); if ($choice.required) { $choice.reasons=@('Setup foundation') } }
    if ($Model.reconfigure) { return }
    $byKey=@{}; foreach ($choice in $Model.choices) { $byKey[$choice.key]=$choice }
    $edges=@(
        @{from='setting:win-tap'; to='windows:AutoHotkey.AutoHotkey'; reason='Win-tap helper'},
        @{from='feature:runtimes'; to='feature:mise'; reason='Developer runtimes'},
        @{from='feature:starship'; to='feature:mise'; reason='Starship prompt'}
    )
    foreach ($id in Get-BuildPackages) { $edges += @{from='feature:runtimes'; to='wsl:'+$id; reason='Developer runtimes'} }
    foreach ($edge in $edges) {
        if ($byKey.ContainsKey($edge.from) -and $byKey[$edge.from].selected -and $byKey.ContainsKey($edge.to)) {
            $byKey[$edge.to].selected=$true; $byKey[$edge.to].reasons += $edge.reason
        }
    }
    foreach ($id in @('curl','ca-certificates')) {
        if ($byKey.ContainsKey('wsl:'+$id)) { $byKey['wsl:'+$id].selected=$true; $byKey['wsl:'+$id].reasons += 'Ubuntu setup' }
    }
}

function Set-WizardChoice($Model,$Choice,[bool]$Enabled) {
    if (-not $Enabled -and ($Choice.required -or $Choice.reasons.Count)) {
        $Model.message='Required by: '+($Choice.reasons -join ', ')+'. Turn off the dependent feature first.'; return
    }
    $Choice.requested=$Enabled
    Resolve-WizardDependencies $Model
}

function Get-WizardReview($Model) {
    $lines=@()
    foreach ($group in @('Desktop','Distractions','App removal','Windows apps','Linux tools')) {
        $items=@($Model.choices | Where-Object group -eq $group)
        if (-not $items.Count) { continue }
        $lines += $group
        foreach ($item in $items) {
            if ($Model.reconfigure) {
                $old=$Model.state.appliedSettings[$item.id]
                $action=if ($old -eq $item.selected) {'Keep'} elseif ($item.selected) {'Apply'} else {'Restore original'}
                $lines += "  ${action}: $($item.title)"
                if ($item.id -eq 'win-tap' -and $item.selected -and -not $old) { $lines += '    Install AutoHotkey v2 if missing; leave other package selections unchanged.' }
            } elseif ($item.selected) {
                $action=if ($item.kind -eq 'remove') {'Remove'} elseif ($item.kind -eq 'setting') {'Apply'} else {'Install'}
                $suffix=if ($item.reasons.Count) {' [required: '+($item.reasons -join ', ')+']'} else {''}
                $lines += "  ${action}: $($item.title)$suffix"
            }
        }
    }
    if (-not $Model.reconfigure) {
        $lines += @('Foundations: PowerToys + Command Palette, Terminal, Ubuntu 24.04 / WSL2 + systemd.',
            'Selected app removals may delete data. Package/source licenses will be accepted.',
            'Ubuntu may restart; save its work first. Windows never reboots automatically.')
    } else { $lines += 'Turning off a setting restores its recorded original values, which may already be enabled.' }
    $lines += 'Sign out/in for shell policies. PowerToys may restart briefly. Widgets may request UAC.'
    $lines += 'Continue to the final APPLY prompt, or go Back to edit.'
    return ,$lines
}

function Get-WizardRows($Model) {
    $group=$Model.screens[$Model.page]; $rows=@()
    if ($group -eq 'Review') {
        $reviewLines=Get-WizardReview $Model
        foreach ($line in $reviewLines) { $rows += @{type='text'; title=$line; description=$line; action=''} }
    } else {
        foreach ($choice in @($Model.choices | Where-Object { $_.group -eq $group -and -not $_.build })) {
            $rows += @{type='choice'; title=$choice.title; description=$choice.description; choice=$choice; action='toggle'}
        }
        $build=@($Model.choices | Where-Object { $_.group -eq $group -and $_.build })
        if ($build.Count) {
            $selected=@($build | Where-Object selected).Count
            $rows += @{type='action'; title="Build prerequisites ($selected/$($build.Count)) - $(if ($Model.expanded) {'collapse'} else {'expand'})"; description='Libraries and compiler packages. Expand to inspect individual choices; runtime dependencies stay selected.'; action='expand'}
            if ($Model.expanded) { foreach ($choice in $build) { $rows += @{type='choice'; title='  '+$choice.title; description=$choice.description; choice=$choice; action='toggle'} } }
        }
        $rows += @{type='action'; title='Select optional'; description='Select all optional choices on this screen.'; action='all'}
        $rows += @{type='action'; title='Clear optional'; description='Clear optional choices while keeping required dependencies.'; action='none'}
        $rows += @{type='action'; title='Recommended defaults'; description='Restore the recommended choices on this screen.'; action='defaults'}
    }
    if ($Model.page -gt 0) { $rows += @{type='action'; title='< Back'; description='Keep choices and return to the previous screen.'; action='back'} }
    $rows += @{type='action'; title=$(if ($group -eq 'Review') {'Continue to approval >'} else {'Next >'}); description='Keep choices and continue.'; action=$(if ($group -eq 'Review') {'finish'} else {'next'})}
    $rows += @{type='action'; title='Cancel'; description='Exit without saving or applying these choices.'; action='cancel'}
    return ,$rows
}

function Update-Wizard($Model,[string]$Key) {
    if ($Model.confirmCancel) {
        if ($Key -eq 'Y') { $Model.cancelled=$true }
        $Model.confirmCancel=$false; return
    }
    $Model.message=''
    $rows=Get-WizardRows $Model
    switch ($Key) {
        'UpArrow' { $Model.focus=[Math]::Max(0,$Model.focus-1); return }
        'DownArrow' { $Model.focus=[Math]::Min($rows.Count-1,$Model.focus+1); return }
        'Home' { $Model.focus=0; return }
        'End' { $Model.focus=$rows.Count-1; return }
        'Escape' { $Model.confirmCancel=$true; return }
        'LeftArrow' { $action='back' }
        'RightArrow' { $action=if ($Model.page -lt $Model.screens.Count-1) {'next'} else {''} }
        { $_ -in @('Spacebar','Enter') } { $action=$rows[$Model.focus].action }
        default { return }
    }
    switch ($action) {
        'toggle' { $choice=$rows[$Model.focus].choice; Set-WizardChoice $Model $choice (-not $choice.selected) }
        'expand' { $Model.expanded=-not $Model.expanded }
        { $_ -in @('all','none','defaults') } {
            foreach ($choice in @($Model.choices | Where-Object group -eq $Model.screens[$Model.page])) {
                if (-not $choice.required) { $choice.requested=if ($action -eq 'defaults') {$choice.default} else {$action -eq 'all'} }
            }
            Resolve-WizardDependencies $Model
            $Model.message='Updated optional choices. Required dependencies remain selected.'
        }
        'back' { $Model.page=[Math]::Max(0,$Model.page-1); $Model.focus=0 }
        'next' { $Model.page=[Math]::Min($Model.screens.Count-1,$Model.page+1); $Model.focus=0 }
        'finish' { $Model.finished=$true }
        'cancel' { $Model.confirmCancel=$true }
    }
    $Model.focus=[Math]::Min($Model.focus,(Get-WizardRows $Model).Count-1)
}

function Split-WizardText([string]$Text,[int]$Width,[int]$Limit) {
    $lines=@(); $remaining=$Text
    while ($remaining.Length -gt $Width -and $lines.Count -lt $Limit-1) {
        $cut=$remaining.LastIndexOf(' ',[Math]::Min($Width-1,$remaining.Length-1))
        if ($cut -le 0) { $cut=$Width }
        $lines += $remaining.Substring(0,$cut); $remaining=$remaining.Substring($cut).TrimStart()
    }
    if ($remaining.Length -gt $Width) { $remaining=$remaining.Substring(0,$Width-3)+'...' }
    $lines += $remaining
    while ($lines.Count -lt $Limit) { $lines += '' }
    return ,$lines
}

function Get-WizardFrame($Model,[int]$Width=80,[int]$Height=25) {
    $rows=Get-WizardRows $Model
    $size=[Math]::Max(1,$Height-14); $start=[Math]::Max(0,$Model.focus-$size+1)
    $end=[Math]::Min($rows.Count,$start+$size)
    $selected=@($Model.choices | Where-Object selected).Count
    $lines=@("PERFECT WIN11  |  $($Model.screens[$Model.page])", "Step $($Model.page+1)/$($Model.screens.Count)  |  $selected selected",
        'Up/Down move | Space toggle | Enter activate', 'Left/Right back/next | Esc cancel | Home/End','')
    for ($i=$start; $i -lt $end; $i++) {
        $row=$rows[$i]; $mark='   '
        if ($row.type -eq 'choice') { $mark=if ($row.choice.selected) {'[x]'} else {'[ ]'} }
        $required=if ($row.type -eq 'choice' -and $row.choice.reasons.Count) {' [required]'} else {''}
        $lines += "$(if ($i -eq $Model.focus) {'>'} else {' '}) $mark $($row.title)$required"
    }
    $lines += "  Rows $($start+1)-$end of $($rows.Count)"
    $focused=$rows[$Model.focus]
    $lines += ''
    $lines += Split-WizardText $focused.description ([Math]::Max(10,$Width-1)) 3
    if ($focused.type -eq 'choice') { $lines += "ID: $($focused.choice.id)  $(if ($focused.choice.reasons.Count) {'Required by: '+($focused.choice.reasons -join ', ')})" }
    else { $lines += '' }
    $message=if ($Model.confirmCancel) {'Cancel without saving? Y = cancel; any other key = continue.'} else {$Model.message}
    $lines += Split-WizardText $message ([Math]::Max(10,$Width-1)) 2
    return ,@($lines | ForEach-Object { if ($_.Length -ge $Width) { $_.Substring(0,[Math]::Max(1,$Width-4))+'...' } else { $_ } })
}

function Test-InteractiveConsole {
    try { return $Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected -and [Console]::WindowWidth -ge 50 -and [Console]::WindowHeight -ge 16 }
    catch { return $false }
}

function Invoke-LineWizardInput($Model,$Answer) {
    if ($null -eq $Answer) { $Model.cancelled=$true; return }
    if ($Model.confirmCancel) { Update-Wizard $Model $Answer.Trim(); return }
    switch ($Answer.Trim().ToLowerInvariant()) {
        'next' { $Model.focus=(Get-WizardRows $Model).Count-2; Update-Wizard $Model Enter; return }
        'back' { Update-Wizard $Model LeftArrow; return }
        'cancel' { Update-Wizard $Model Escape; return }
    }
    $number=0; $rows=Get-WizardRows $Model
    if ([int]::TryParse($Answer,[ref]$number) -and $number -ge 1 -and $number -le $rows.Count) { $Model.focus=$number-1; Update-Wizard $Model Enter }
    else { $Model.message='Enter a displayed number, next, back, or cancel. Blank input does not accept.' }
}

function Save-WizardChoices($Model) {
    foreach ($choice in $Model.choices) {
        if ($choice.kind -eq 'setting') { $Model.state.settings[$choice.id]=[bool]$choice.selected }
        elseif ($choice.kind -eq 'remove') {
            ($Model.state.remove | Where-Object id -eq $choice.id).selected=[bool]$choice.selected
        } else {
            $item=$Model.state.install | Where-Object { $_.kind -eq $choice.kind -and $_.id -eq $choice.id }
            $item.selected=[bool]$choice.selected; $item['requested']=[bool]$choice.requested
        }
    }
    foreach ($item in $Model.state.remove) { if ($item.kind -eq 'setting') { $item.selected=$Model.state.settings[$item.id] } }
}

function Show-SetupWizard($Model) {
    if (Test-InteractiveConsole) {
        $visible=[Console]::CursorVisible; $color=[Console]::ForegroundColor
        try {
            [Console]::CursorVisible=$false; $previous=''
            while (-not $Model.finished -and -not $Model.cancelled) {
                $width=[Console]::WindowWidth; $height=[Console]::WindowHeight
                if ($width -lt 50 -or $height -lt 16) { $frame=if ($Model.confirmCancel) {'Cancel? Y = yes; any other key = continue.'} else {'Enlarge to 50 x 16, or Esc to cancel.'} }
                else { $frame=(Get-WizardFrame $Model $width $height) -join "`n" }
                if ($frame -ne $previous) { [Console]::Clear(); [Console]::Write($frame); $previous=$frame }
                if ([Console]::KeyAvailable) {
                    $key=[Console]::ReadKey($true)
                    if ($width -ge 50 -and $height -ge 16) { Update-Wizard $Model $(if ($Model.confirmCancel) {[string]$key.KeyChar} else {[string]$key.Key}) }
                    elseif ($Model.confirmCancel) { Update-Wizard $Model ([string]$key.KeyChar) }
                    elseif ($key.Key -eq 'Escape') { Update-Wizard $Model Escape }
                } else { Start-Sleep -Milliseconds 100 }
            }
        } finally { [Console]::CursorVisible=$visible; [Console]::ForegroundColor=$color; [Console]::WriteLine() }
    } else {
        while (-not $Model.finished -and -not $Model.cancelled) {
            Write-Host "`nPERFECT WIN11 | $($Model.screens[$Model.page]) | $($Model.page+1)/$($Model.screens.Count)"
            $rows=Get-WizardRows $Model
            for ($i=0; $i -lt $rows.Count; $i++) {
                $row=$rows[$i]; $mark=if ($row.type -eq 'choice') { if ($row.choice.selected) {'[x]'} else {'[ ]'} } else {''}
                Write-Host "$($i+1). $mark $($row.title)"
                if ($row.description) { Write-Host "   $($row.description)" }
                if ($row.type -eq 'choice' -and $row.choice.reasons.Count) { Write-Host ('   Required by: '+($row.choice.reasons -join ', ')) }
            }
            Write-Host $Model.message
            if ($Model.confirmCancel) { Write-Host 'Cancel without saving? Type Y to cancel, or anything else to continue.' }
            if ([Console]::IsInputRedirected) { $answer=[Console]::ReadLine() } else { $answer=Read-Host 'Number to toggle/activate, next, back, cancel' }
            Invoke-LineWizardInput $Model $answer
        }
    }
    if ($Model.cancelled) { return $false }
    Save-WizardChoices $Model
    return $true
}

Export-ModuleMember -Function *
