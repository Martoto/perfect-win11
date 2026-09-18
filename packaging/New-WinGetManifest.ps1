#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Installer,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Verify-Release.ps1" -Installer $Installer -OutputDirectory $OutputDirectory
$version=Assert-ReleaseInstaller -Installer $Installer
$hash=(Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash
$url="https://github.com/Martoto/perfect-win11/releases/download/v$version/PerfectWin11-$version-Setup.exe"
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$identity="PackageIdentifier: Martoto.PerfectWin11`r`nPackageVersion: $version"
@"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.version.1.6.0.schema.json
$identity
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.6.0
"@ | Set-Content -LiteralPath (Join-Path $OutputDirectory 'Martoto.PerfectWin11.yaml') -Encoding UTF8
@"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.installer.1.6.0.schema.json
$identity
MinimumOSVersion: 10.0.22000.0
InstallerType: inno
Scope: user
InstallModes:
- interactive
- silent
- silentWithProgress
UpgradeBehavior: install
Commands:
- perfect-win11
AppsAndFeaturesEntries:
- DisplayName: Perfect Win11
  Publisher: Daniel Salles
  DisplayVersion: $version
  ProductCode: '{7D2A0B15-AD80-4E5E-BBB4-9F28B5C30D19}_is1'
Installers:
- Architecture: x64
  InstallerUrl: $url
  InstallerSha256: $hash
ManifestType: installer
ManifestVersion: 1.6.0
"@ | Set-Content -LiteralPath (Join-Path $OutputDirectory 'Martoto.PerfectWin11.installer.yaml') -Encoding UTF8
@"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.defaultLocale.1.6.0.schema.json
$identity
PackageLocale: en-US
Publisher: Daniel Salles
PublisherUrl: https://github.com/Martoto
PackageName: Perfect Win11
PackageUrl: https://github.com/Martoto/perfect-win11
License: MIT
LicenseUrl: https://github.com/Martoto/perfect-win11/blob/v$version/LICENSE
ShortDescription: A preview-first Windows 11 setup and customization wizard.
Moniker: perfect-win11
Tags:
- windows11
- setup
- customization
ReleaseNotesUrl: https://github.com/Martoto/perfect-win11/releases/tag/v$version
ManifestType: defaultLocale
ManifestVersion: 1.6.0
"@ | Set-Content -LiteralPath (Join-Path $OutputDirectory 'Martoto.PerfectWin11.locale.en-US.yaml') -Encoding UTF8
Write-Output "Generated WinGet manifests for signed release $version in $OutputDirectory."
