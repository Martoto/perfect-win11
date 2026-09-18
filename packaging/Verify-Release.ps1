#Requires -Version 5.1
[CmdletBinding()]
param([string]$Installer, [string]$Payload, [string]$OutputDirectory)
$ErrorActionPreference='Stop'
$script:ReleaseRepository=Split-Path $PSScriptRoot

function Get-ReleaseVersion {
    $version=(Get-Content -LiteralPath (Join-Path $script:ReleaseRepository 'VERSION') -Raw).Trim()
    if ($version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') { throw 'VERSION must contain three numeric components.' }
    foreach ($part in $version.Split('.')) { if ([long]$part -gt 65534) { throw 'VERSION exceeds Windows version limits.' } }
    return $version
}

function Get-ReleaseSignerThumbprint {
    $thumbprint=($env:SIGNING_CERT_SHA1 -replace '\s','').ToUpperInvariant()
    if ($thumbprint -notmatch '^[A-F0-9]{40}$') { throw 'SIGNING_CERT_SHA1 must identify the enrolled SSL.com code signing certificate.' }
    return $thumbprint
}

function Assert-ReleaseSignature {
    param([Parameter(Mandatory=$true)][string]$Path)
    $expected=Get-ReleaseSignerThumbprint
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing signed file: $Path" }
    $signature=Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid') { throw "Invalid Authenticode signature ($($signature.Status)): $Path" }
    if (-not $signature.SignerCertificate -or $signature.SignerCertificate.Thumbprint -ne $expected) { throw "Unexpected release signer: $Path" }
    if (-not $signature.TimeStamperCertificate) { throw "Missing trusted timestamp: $Path" }
    return $signature
}

function Assert-ReleaseInstaller {
    param([Parameter(Mandatory=$true)][string]$Installer)
    $version=Get-ReleaseVersion
    [void](Assert-ReleaseSignature -Path $Installer)
    $info=[Diagnostics.FileVersionInfo]::GetVersionInfo((Resolve-Path -LiteralPath $Installer).Path)
    $fileVersion='{0}.{1}.{2}.{3}' -f $info.FileMajorPart,$info.FileMinorPart,$info.FileBuildPart,$info.FilePrivatePart
    if ($fileVersion -ne "$version.0") { throw "Installer file version '$fileVersion' does not match VERSION '$version'." }
    return $version
}

# Dot sourcing shares the same trust gates with signing and manifest generation.
if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $Installer -or -not $Payload) { throw 'Both -Installer and -Payload are required.' }
$version=Assert-ReleaseInstaller -Installer $Installer
if (-not (Test-Path -LiteralPath $Payload -PathType Container)) { throw 'Payload directory is missing.' }
$payloadVersion=(Get-Content -LiteralPath (Join-Path $Payload 'VERSION') -Raw).Trim()
if ($payloadVersion -ne $version) { throw 'Payload VERSION differs from the installer.' }
foreach ($required in @('perfect-win11.exe','Setup.ps1','Restore-Settings.ps1','lib')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Payload $required))) { throw "Required payload missing: $required" }
}
$files=@(Get-ChildItem -LiteralPath $Payload -Recurse -File | Where-Object Extension -in @('.exe','.dll','.ps1','.psm1'))
foreach ($file in $files) { [void](Assert-ReleaseSignature -Path $file.FullName) }
$launcherVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $Payload 'perfect-win11.exe')).FileVersion
if ($launcherVersion -ne "$version.0") { throw 'Launcher version differs from VERSION.' }
$commit=(& git -C $script:ReleaseRepository rev-parse HEAD | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[a-f0-9]{40}$') { throw 'Cannot establish source commit.' }
$sourceState=@(& git -C $script:ReleaseRepository status --porcelain --untracked-files=normal)
if ($LASTEXITCODE -ne 0) { throw 'Cannot establish source state.' }
if ($sourceState.Count) { throw 'Release verification requires a clean source checkout.' }
if (-not $OutputDirectory) { $OutputDirectory=Split-Path (Resolve-Path -LiteralPath $Installer).Path }
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$hash=(Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash
$name=Split-Path $Installer -Leaf
"$hash  $name" | Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS') -Encoding ASCII
$signature=Assert-ReleaseSignature -Path $Installer
[ordered]@{
    version=$version
    sourceCommit=$commit
    installer=$name
    sha256=$hash
    signerThumbprint=$signature.SignerCertificate.Thumbprint
    signerSubject=$signature.SignerCertificate.Subject
    timestampSignerThumbprint=$signature.TimeStamperCertificate.Thumbprint
    verifiedPayloadFiles=$files.Count
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'release-metadata.json') -Encoding UTF8
Write-Output "Verified release $version ($hash)."
