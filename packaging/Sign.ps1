#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Verify-Release.ps1"
$thumbprint=Get-ReleaseSignerThumbprint
if (-not $env:SIGNTOOL_PATH -or -not [IO.Path]::IsPathRooted($env:SIGNTOOL_PATH) -or -not (Test-Path -LiteralPath $env:SIGNTOOL_PATH -PathType Leaf)) {
    throw 'SIGNTOOL_PATH must be the absolute path to the pinned Windows SDK signtool.exe.'
}
if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Signing target is missing: $Path" }
$innoTemporary=([IO.Path]::GetFileName($Path) -match '^(uninst|setup)\.e(32|64)\.tmp$')
if ([IO.Path]::GetExtension($Path) -notin @('.exe','.dll','.ps1','.psm1') -and -not $innoTemporary) { throw 'Unsupported signing target.' }
if ($innoTemporary -and ([Diagnostics.FileVersionInfo]::GetVersionInfo((Resolve-Path -LiteralPath $Path).Path).ProductName).Trim() -ne 'Perfect Win11') {
    throw 'Unexpected product in Inno temporary signing target.'
}
$certificate=Get-Item -LiteralPath "Cert:\CurrentUser\My\$thumbprint" -ErrorAction Stop
if (-not $certificate.HasPrivateKey) { throw 'The enrolled certificate has no accessible CKA private key.' }
if ($certificate.NotBefore -gt (Get-Date) -or $certificate.NotAfter -lt (Get-Date)) { throw 'Signing certificate is outside its validity period.' }
if (-not @($certificate.EnhancedKeyUsageList | Where-Object { $_.ObjectId.Value -eq '1.3.6.1.5.5.7.3.3' }).Count) { throw 'Certificate lacks code signing usage.' }
# eSigner CKA must already be configured by CI. Never pass credentials on the CLI.
# SSL.com documents RFC3161 at http://ts.ssl.com (not legacy /t).
# SignTool uses Windows SIPs for PS1/PSM1 as well as PE files; use matching x64 SDK.
# Set-AuthenticodeSignature uses legacy timestamp APIs, incompatible with this TSA.
& $env:SIGNTOOL_PATH sign /fd SHA256 /tr http://ts.ssl.com /td SHA256 /sha1 $thumbprint $Path
if ($LASTEXITCODE -ne 0) { throw 'eSigner CKA signing or timestamping failed.' }
[void](Assert-ReleaseSignature -Path $Path)
& $env:SIGNTOOL_PATH verify /pa /all /tw $Path
if ($LASTEXITCODE -ne 0) { throw 'SignTool signature verification failed.' }
