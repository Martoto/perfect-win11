#Requires -Version 5.1
[CmdletBinding()]
param([switch]$IncludeSigningProvider)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$pins=Get-Content "$PSScriptRoot\tools.lock.json" -Raw | ConvertFrom-Json
$directory=Join-Path $repo 'artifacts\tools'
[void][IO.Directory]::CreateDirectory($directory)
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
function Get-PinnedDownload($Pin,[string]$Destination) {
    if (-not (Test-Path -LiteralPath $Destination)) { Invoke-WebRequest -UseBasicParsing -Uri $Pin.url -OutFile $Destination }
    if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ne $Pin.sha256) {
        throw "Checksum mismatch for $Destination. Remove that cached file and investigate before retrying."
    }
}
$archive=Join-Path $directory 'inno.zip'
Get-PinnedDownload $pins.inno $archive
$expanded=Join-Path $directory ('inno-'+$pins.inno.version)
Expand-Archive -LiteralPath $archive -DestinationPath $expanded -Force
$compiler=Join-Path $expanded 'tools\ISCC.exe'
$signature=Get-AuthenticodeSignature -LiteralPath $compiler
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Pyrsys B.V.') { throw 'Inno compiler signature validation failed.' }
if ($IncludeSigningProvider) { Get-PinnedDownload $pins.cka (Join-Path $directory 'esigner-cka.exe') }
Write-Output $compiler
