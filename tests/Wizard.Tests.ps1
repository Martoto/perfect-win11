Import-Module "$PSScriptRoot\..\lib\Wizard.psm1" -Force

Describe 'Guided selection model' {
    BeforeEach {
        $manifest=@{schemaVersion=1; windows=@(); wsl=@()}
        $state=New-SetupState $manifest (Get-InstallCatalog) (Get-RemovalCatalog) 'user'
        $model=New-WizardModel $state
    }
    It 'starts with friendly desktop checkboxes and conditional AutoHotkey' {
        $model.screens[0] | Should Be 'Desktop'
        $choice=$model.choices | Where-Object id -eq 'AutoHotkey.AutoHotkey'
        $choice.requested | Should Be $false
        $choice.selected | Should Be $true
        $choice.reasons[0] | Should Be 'Win-tap helper'
    }
    It 'releases AutoHotkey immediately when Win-tap is unchecked' {
        $model.focus=1; Update-Wizard $model Spacebar
        ($model.choices | Where-Object id -eq 'AutoHotkey.AutoHotkey').selected | Should Be $false
        $state.settings['win-tap'] | Should Be $true
    }
    It 'preserves choices when moving Back and Next' {
        Update-Wizard $model Spacebar
        Update-Wizard $model RightArrow
        $model.page | Should Be 1
        Update-Wizard $model LeftArrow
        ($model.choices | Where-Object id -eq 'taskbar').selected | Should Be $false
    }
    It 'clamps navigation at both ends' {
        Update-Wizard $model UpArrow; $model.focus | Should Be 0
        Update-Wizard $model End; Update-Wizard $model DownArrow
        $model.focus | Should Be ((Get-WizardRows $model).Count-1)
    }
    It 'explains why required choices cannot be cleared' {
        $choice=$model.choices | Where-Object id -eq 'Microsoft.PowerToys'
        Set-WizardChoice $model $choice $false
        $choice.selected | Should Be $true
        $model.message | Should Match 'foundation'
    }
    It 'keeps build dependencies selected and explains their parent feature' {
        $choice=$model.choices | Where-Object id -eq 'build-essential'
        Set-WizardChoice $model $choice $false
        $choice.selected | Should Be $true
        $model.message | Should Match 'Developer runtimes'
    }
    It 'clears optional items as a group without silently restoring their explicit choices' {
        $model.page=3
        $rows=Get-WizardRows $model
        for ($i=0;$i -lt $rows.Count;$i++) { if ($rows[$i].action -eq 'none') {$model.focus=$i} }
        Update-Wizard $model Enter
        ($model.choices | Where-Object id -eq 'Microsoft.VisualStudioCode').selected | Should Be $false
        ($model.choices | Where-Object id -eq 'Microsoft.PowerToys').selected | Should Be $true
        ($model.choices | Where-Object id -eq 'AutoHotkey.AutoHotkey').requested | Should Be $false
        ($model.choices | Where-Object id -eq 'AutoHotkey.AutoHotkey').selected | Should Be $true
    }
    It 'restores recommended defaults per screen' {
        Update-Wizard $model Spacebar
        $rows=Get-WizardRows $model
        for ($i=0;$i -lt $rows.Count;$i++) { if ($rows[$i].action -eq 'defaults') {$model.focus=$i} }
        Update-Wizard $model Enter
        ($model.choices | Where-Object id -eq 'taskbar').selected | Should Be $true
    }
    It 'expands build prerequisites without losing selections' {
        $model.page=4
        $count=(Get-WizardRows $model).Count
        $rows=Get-WizardRows $model
        for ($i=0;$i -lt $rows.Count;$i++) { if ($rows[$i].action -eq 'expand') {$model.focus=$i} }
        Update-Wizard $model Enter
        ((Get-WizardRows $model).Count -gt $count) | Should Be $true
        ($model.choices | Where-Object id -eq 'build-essential').selected | Should Be $true
    }
    It 'requires explicit cancellation and leaves the supplied state untouched' {
        $before=$state | ConvertTo-Json -Depth 30 -Compress
        Update-Wizard $model Spacebar
        Update-Wizard $model Escape
        $model.cancelled | Should Be $false
        Update-Wizard $model Enter
        $model.cancelled | Should Be $false
        Update-Wizard $model Escape; Update-Wizard $model Y
        $model.cancelled | Should Be $true
        ($state | ConvertTo-Json -Depth 30 -Compress) | Should Be $before
    }
    It 'does not finish on RightArrow in review' {
        $model.page=$model.screens.Count-1
        Update-Wizard $model RightArrow
        $model.finished | Should Be $false
        Invoke-LineWizardInput $model next
        $model.finished | Should Be $true
    }
    It 'shows review entries as individual scrollable lines' {
        $model.page=$model.screens.Count-1
        $rows=Get-WizardRows $model
        ($rows.Count -gt 30) | Should Be $true
        @($rows | Where-Object { $_.title -isnot [string] }).Count | Should Be 0
    }
    It 'handles fallback toggling and rejects empty acceptance' {
        Invoke-LineWizardInput $model '1'
        ($model.choices | Where-Object id -eq 'taskbar').selected | Should Be $false
        Invoke-LineWizardInput $model ''
        $model.page | Should Be 0
        $model.finished | Should Be $false
        Invoke-LineWizardInput $model $null
        $model.cancelled | Should Be $true
    }
    It 'renders bounded frames and retains focus after a resize' {
        Update-Wizard $model End
        $focus=$model.focus
        foreach ($width in @(50,80,120)) {
            $frame=Get-WizardFrame $model $width 18
            @($frame | Where-Object { $_.Length -gt $width }).Count | Should Be 0
            ($frame.Count -le 18) | Should Be $true
        }
        $model.focus | Should Be $focus
    }
    It 'saves effective dependencies and explicit choices separately' {
        Save-WizardChoices $model
        $ahk=$state.install | Where-Object id -eq 'AutoHotkey.AutoHotkey'
        $ahk.selected | Should Be $true
        $ahk.requested | Should Be $false
    }
    It 'limits reconfiguration to desktop and distraction settings' {
        $config=New-WizardModel $state -Reconfigure
        $config.screens.Count | Should Be 3
        @($config.choices | Where-Object kind -ne 'setting').Count | Should Be 0
        ($config.screens -contains 'App removal') | Should Be $false
    }
}

Describe 'Settings state migration' {
    BeforeEach {
        $state=New-SetupState @{schemaVersion=1; windows=@(); wsl=@()} @() @() 'user'
        $state.schemaVersion=1
        foreach ($field in @('settings','appliedSettings','setupComplete','reconfiguration','history')) { $state.Remove($field) }
    }
    It 'maps completed legacy desktop steps without inventing applied distractions' {
        $state.steps.taskbar=@{status='done'; error=$null}
        $read=ConvertTo-SetupV2 $state
        $read.schemaVersion | Should Be 2
        $read.settings.taskbar | Should Be $true
        $read.appliedSettings.taskbar | Should Be $true
        $read.appliedSettings['win-tap'] | Should Be $false
        $read.settings.ads | Should Be $false
        $read.setupComplete | Should Be $false
    }
    It 'recognizes a completed legacy setup' {
        foreach ($name in @('winget','windows-inventory','powertoys-settings','wsl-features','wsl-update','wsl-user','wsl-systemd','linux-install','linux-verify','terminal-profile','taskbar','win-tap')) { $state.steps[$name]=@{status='done'; error=$null} }
        (ConvertTo-SetupV2 $state).setupComplete | Should Be $true
    }
    It 'rejects unknown settings and invalid types in saved v2 state' {
        $read=ConvertTo-SetupV2 $state
        $read.settings.taskbar='yes'
        { ConvertTo-SetupV2 $read } | Should Throw
    }
}
