Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\Core.psm1"

function Get-WslDistributions {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return @() }
    $output = & wsl.exe --list --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    @($output | ForEach-Object { ($_ -replace "`0",'').Trim() } | Where-Object { $_ })
}

function Select-WslDistribution($State) {
    $existing = @(Get-WslDistributions)
    $compatible = @()
    foreach ($name in $existing) {
        if ($name -notmatch '^[A-Za-z0-9._-]+$' -or $name -notmatch 'Ubuntu') { continue }
        $release = & wsl.exe -d $name -u root -- cat /etc/os-release 2>$null
        if ($LASTEXITCODE -eq 0 -and ($release -join "`n") -match '(?m)^VERSION_ID="24\.04"' -and ($release -join "`n") -match '(?m)^ID=ubuntu') { $compatible += $name }
    }
    if ($compatible.Count) {
        Write-Host 'Compatible existing Ubuntu distributions (reuse updates packages/configuration and restarts this distro):'
        for ($i=0; $i -lt $compatible.Count; $i++) { Write-Host "$($i+1). $($compatible[$i])" }
        $answer = Read-Host 'Enter a number to explicitly reuse, or Enter to install Ubuntu-24.04'
        $index=0
        if ($answer -and [int]::TryParse($answer,[ref]$index) -and $index -ge 1 -and $index -le $compatible.Count) {
            $State.distro=$compatible[$index-1]; $State.reuseApproved=$true; return
        }
        if ($answer) { throw 'Invalid distribution choice.' }
    }
    if ('Ubuntu-24.04' -in $existing) { throw 'Ubuntu-24.04 already exists. Explicitly reuse a compatible installation; existing distributions are never reset.' }
}

function Initialize-WslUser($State,$Path) {
    if ($State.distro -notin @(Get-WslDistributions)) {
        $State.steps['distro-created']=@{status='running'; error=$null}; Write-Json $Path $State
        Write-Host 'Complete the Ubuntu username/password prompts. If a Linux shell opens, type exit to return to setup.'
        # Keep first-run output/input attached to the terminal: capturing it can hide OOBE prompts.
        & wsl.exe --install -d $State.distro
        if ($LASTEXITCODE -ne 0) { throw "Ubuntu installation/first-run failed (exit $LASTEXITCODE). Complete initialization and resume." }
        $State.steps['distro-created']=@{status='done'; error=$null}; Write-Json $Path $State
    } elseif (-not $State.reuseApproved -and -not $State.steps.ContainsKey('distro-created')) {
        throw 'Distribution appeared after selection. Explicit reuse is required; start a new selection after archiving the state.'
    }
    if ($State.steps.ContainsKey('distro-created') -and $State.steps['distro-created'].status -eq 'running') {
        Write-Host 'Finish the interrupted Ubuntu account initialization; type exit to return.'
        & wsl.exe -d $State.distro
        if ($LASTEXITCODE -ne 0) { throw 'Ubuntu account initialization is unfinished.' }
        $State.steps['distro-created'].status='done'; Write-Json $Path $State
    }
    Invoke-Native wsl.exe @('--set-version',$State.distro,'2')
    $name = (& wsl.exe -d $State.distro -- id -un 2>$null) -join ''
    if ($LASTEXITCODE -ne 0 -or $name.Trim() -eq 'root') {
        Write-Host 'Complete Ubuntu account creation in the window below, then type exit to return. Choose a normal non-root Linux account.'
        # Interactive distro launch follows the supported first-run OOBE flow.
        & wsl.exe -d $State.distro
        if ($LASTEXITCODE -ne 0) { throw 'Ubuntu initialization failed; resume after completing account creation.' }
        $name = Invoke-Native wsl.exe @('-d',$State.distro,'--','id','-un') -Capture
    }
    $name=$name.Trim()
    if ($name -eq 'root' -or $name -notmatch '^[a-z_][a-z0-9_-]*$') { throw 'Ubuntu needs a normal default Linux user. Complete its account creation and resume.' }
    $release=Invoke-Native wsl.exe @('-d',$State.distro,'--','cat','/etc/os-release') -Capture
    if ($release -notmatch '(?m)^VERSION_ID="24\.04"' -or $release -notmatch '(?m)^ID=ubuntu') { throw 'Only Ubuntu 24.04 LTS is supported.' }
    $State.linuxUser=$name; Write-Json $Path $State
    Invoke-Native wsl.exe @('--set-default',$State.distro)
}

function Invoke-LinuxPhase($State,$Path,[ValidateSet('systemd','install','verify')][string]$Phase) {
    $plan=@{user=$State.linuxUser; apt=@($State.install | Where-Object { $_.selected -and $_.kind -eq 'wsl' } | ForEach-Object { $_.id });
        features=@($State.install | Where-Object { $_.selected -and $_.kind -eq 'feature' } | ForEach-Object { $_.id }); phase=$Phase}
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($plan | ConvertTo-Json -Compress -Depth 10)))
    $script=Get-Content -LiteralPath "$PSScriptRoot\..\assets\linux-setup.py" -Raw
    $oldEncoding=$OutputEncoding
    try {
        $OutputEncoding=New-Object Text.UTF8Encoding $false
        $script | & wsl.exe -d $State.distro -u root -- env "PW11_PLAN=$encoded" python3 -
        $code=$LASTEXITCODE
        $linuxState = & wsl.exe -d $State.distro -u root -- cat /var/lib/perfect-win11/state.json
        if ($LASTEXITCODE -eq 0) { $State.linux=ConvertTo-Map (($linuxState -join "`n") | ConvertFrom-Json); Write-Json $Path $State }
        if ($code -ne 0) { throw "Linux $Phase failed (exit $code). Individual results are in state.linux and /var/lib/perfect-win11/state.json." }
    } finally { $OutputEncoding=$oldEncoding }
}

Export-ModuleMember -Function *
