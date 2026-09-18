#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$AcceptanceRecord, [switch]$Unsigned)
$ErrorActionPreference='Stop'

function Assert-ReleaseAcceptance($Record,[string]$Version,[string]$Hash,[string]$Commit,[switch]$Unsigned) {
    if ($Record.schemaVersion -ne 1 -or $Record.version -cne $Version -or
        $Record.installerSha256 -ine $Hash -or $Record.sourceCommit -ine $Commit) {
        throw 'Acceptance record must match the exact candidate version, installer SHA256 and source commit.'
    }
    if (-not $Record.testedBy -or -not $Record.evidence -or -not $Record.testedAt) { throw 'Record the tester, test date and evidence location.' }
    $date=[DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Record.testedAt,[ref]$date)) { throw 'Invalid acceptance test date.' }
    foreach ($name in @('windows11Home','windows11Pro','originalSetupMatrix','wizardAndReconfiguration',
        'runtimesDockerAndVSCode','keyboardAndLogin','silentInstallAndNoConfiguration',
        'upgradeReinstallAndRecovery','uninstallAndPathPreservation','concurrentOperations',
        'wingetLocalManifest','installedSignatures')) {
        $expected=if ($Unsigned -and $name -eq 'installedSignatures') { 'not-applicable' } else { 'passed' }
        if ($Record.results.$name -cne $expected) { throw "Acceptance check must be ${expected}: $name" }
    }
}
if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $AcceptanceRecord) { throw '-AcceptanceRecord is required. Start with acceptance.example.json and record actual VM results.' }
$record=Get-Content -LiteralPath $AcceptanceRecord -Raw | ConvertFrom-Json
. "$PSScriptRoot\Verify-Release.ps1" -Unsigned:$Unsigned
$version=Get-ReleaseVersion
$tag="v$version"
$repository='Martoto/perfect-win11'
$release=(& gh release view $tag --repo $repository --json isDraft | Out-String) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $release.isDraft) { throw 'Expected an existing draft release. Published releases are never replaced.' }
$commit=(& gh api "repos/$repository/commits/$tag" --jq .sha | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[a-f0-9]{40}$') { throw 'Cannot establish the remote tag commit.' }
$directory=Join-Path (Split-Path $PSScriptRoot) ('artifacts\publication-'+[guid]::NewGuid().ToString())
[void][IO.Directory]::CreateDirectory($directory)
& gh release download $tag --repo $repository --dir $directory --pattern "PerfectWin11-$version-Setup.exe" --pattern release-metadata.json
if ($LASTEXITCODE -ne 0) { throw 'Could not download the exact draft assets.' }
$installer=Join-Path $directory "PerfectWin11-$version-Setup.exe"
[void](Assert-ReleaseInstaller $installer -Unsigned:$Unsigned)
$metadata=Get-Content (Join-Path $directory 'release-metadata.json') -Raw | ConvertFrom-Json
$hash=(Get-FileHash $installer -Algorithm SHA256).Hash
$mode=if ($Unsigned) { 'unsigned' } else { 'signed' }
if ($metadata.version -cne $version -or $metadata.sha256 -ine $hash -or $metadata.sourceCommit -ine $commit -or
    $metadata.signingMode -cne $mode) { throw 'Candidate metadata does not match the downloaded installer, signing mode and tag.' }
if (-not $Unsigned -and $metadata.signerThumbprint -ine (Get-ReleaseSignerThumbprint)) { throw 'Candidate signer does not match.' }
if ($Unsigned -and ($metadata.signerThumbprint -or $metadata.signerSubject -or $metadata.timestampSignerThumbprint)) { throw 'Unsigned metadata must not claim a signer.' }
Assert-ReleaseAcceptance $record $version $hash $commit -Unsigned:$Unsigned
if ($PSCmdlet.ShouldProcess("$repository/$tag ($hash)",'Publish the accepted draft without rebuilding')) {
    $evidenceFile=Join-Path $directory 'acceptance.json'
    Copy-Item -LiteralPath $AcceptanceRecord -Destination $evidenceFile
    & gh release upload $tag $evidenceFile --repo $repository --clobber
    if ($LASTEXITCODE -ne 0) { throw 'Could not attach acceptance evidence.' }
    & gh release edit $tag --repo $repository --draft=false --latest
    if ($LASTEXITCODE -ne 0) { throw 'Publication failed.' }
}
