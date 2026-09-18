#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Provision signing only on an ephemeral GitHub-hosted runner. See RELEASE.md for local signing prerequisites.'
}
foreach ($name in @('ESIGNER_USERNAME','ESIGNER_PASSWORD','ESIGNER_TOTP_SECRET','SIGNING_CERT_SHA1')) {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "Missing release environment secret: $name" }
}
$repo=Split-Path $PSScriptRoot
$pins=Get-Content "$PSScriptRoot\tools.lock.json" -Raw | ConvertFrom-Json
$installer=Join-Path $repo 'artifacts\tools\esigner-cka.exe'
if ((Get-FileHash $installer -Algorithm SHA256).Hash -ne $pins.cka.sha256) { throw 'eSigner CKA installer hash mismatch.' }
$directory=Join-Path $env:RUNNER_TEMP 'PerfectWin11-eSigner'
$process=Start-Process -FilePath $installer -ArgumentList @('/CURRENTUSER','/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/DIR="'+$directory+'"')) -Wait -PassThru -WindowStyle Hidden
if ($process.ExitCode -ne 0) { throw "eSigner CKA installer failed: $($process.ExitCode)" }
foreach ($tool in @('RegisterKSP.exe','eSignerCSP.Config.exe')) {
    & (Join-Path $directory $tool) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "eSigner provisioning failed at $tool" }
}
$cka=Join-Path $directory 'eSignerCKATool.exe'
# Credentials come only from protected environment secrets, never workflow expressions in shell code.
& $cka config -mode product -user $env:ESIGNER_USERNAME -pass $env:ESIGNER_PASSWORD -totp $env:ESIGNER_TOTP_SECRET -key (Join-Path $directory 'master.key') -r | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'eSigner account configuration failed.' }
& $cka unload | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'eSigner unload failed.' }
& $cka load | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'eSigner certificate loading failed.' }
$signTool=Join-Path ${env:ProgramFiles(x86)} ('Windows Kits\10\bin\'+$pins.windowsSdk+'\x64\signtool.exe')
if (-not (Test-Path -LiteralPath $signTool)) { throw "Pinned Windows SDK missing: $($pins.windowsSdk)" }
$env:SIGNTOOL_PATH=$signTool
"SIGNTOOL_PATH=$signTool" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
. "$PSScriptRoot\Verify-Release.ps1"
$thumbprint=Get-ReleaseSignerThumbprint
if (-not (Test-Path "Cert:\CurrentUser\My\$thumbprint")) { throw 'Enrolled signing certificate was not loaded.' }
