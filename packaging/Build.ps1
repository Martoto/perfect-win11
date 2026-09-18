#Requires -Version 5.1
[CmdletBinding()]
param([switch]$LauncherOnly, [string]$IsccPath, [switch]$ReleaseSigned)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$version=(Get-Content -LiteralPath "$repo\VERSION" -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'VERSION must be three numeric components.' }
foreach ($part in $version.Split('.')) { if ([int]$part -gt 65534) { throw 'Version component exceeds Windows file version limit.' } }
$artifacts=Join-Path $repo 'artifacts'
$payload=Join-Path $artifacts 'payload'
if ((Test-Path -LiteralPath $artifacts) -and ((Get-Item -LiteralPath $artifacts).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'The artifacts directory must not be a link.'
}
[void][IO.Directory]::CreateDirectory($artifacts)
$buildLock=[IO.File]::Open((Join-Path $artifacts 'build.lock'),'OpenOrCreate','ReadWrite','None')
try {
    # Only this generated directory is replaced; never touch repository source or user state.
    $resolved=[IO.Path]::GetFullPath($payload)
    if ($resolved -ne [IO.Path]::GetFullPath((Join-Path $repo 'artifacts\payload'))) { throw 'Unsafe staging path.' }
    if (Test-Path $payload) {
        if ((Get-Item $payload).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Staging must not be a link.' }
        if (@(Get-ChildItem -LiteralPath $payload -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Staging must not contain links.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    [void][IO.Directory]::CreateDirectory($payload)
    foreach ($name in @('Setup.ps1','Restore-Settings.ps1','lib','assets','app-list.example.json','app-list.schema.json','README.md','VALIDATION.md','LICENSE','VERSION')) {
        Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $payload -Recurse
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $payload 'packaging'))
    Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.md' | Copy-Item -Destination (Join-Path $payload 'packaging')
    $metadata=Join-Path $artifacts 'AssemblyInfo.cs'
    @"
using System.Reflection;
[assembly: AssemblyTitle("Perfect Win11")]
[assembly: AssemblyProduct("Perfect Win11")]
[assembly: AssemblyCompany("Daniel Salles")]
[assembly: AssemblyCopyright("Copyright (c) 2026 Daniel Salles")]
[assembly: AssemblyVersion("$version.0")]
[assembly: AssemblyFileVersion("$version.0")]
"@ | Set-Content -LiteralPath $metadata -Encoding UTF8
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:exe /platform:x64 /optimize+ "/win32manifest:$PSScriptRoot\launcher.manifest" "/out:$payload\perfect-win11.exe" "$PSScriptRoot\Launcher.cs" $metadata
    if ($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed.' }
    '<?xml version="1.0"?><configuration><startup><supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.8" /></startup></configuration>' | Set-Content "$payload\perfect-win11.exe.config" -Encoding UTF8
    if ($LauncherOnly) { return }
    if (-not $IsccPath) { $IsccPath=Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe' }
    if (-not (Test-Path -LiteralPath $IsccPath)) { throw 'Supply -IsccPath pointing to the pinned Inno Setup compiler. See packaging/RELEASE.md.' }
    $options=@("/DAppVersion=$version","/DPayloadDir=$payload","/DOutputDir=$artifacts")
    if ($ReleaseSigned) {
        $files=@(Get-ChildItem $payload -Recurse -File | Where-Object Extension -in @('.exe','.ps1','.psm1'))
        foreach ($file in $files) { & "$PSScriptRoot\Sign.ps1" -Path $file.FullName }
        $options+='/DReleaseSigned'
        $options+='/Sesigner=powershell.exe -NoProfile -ExecutionPolicy Bypass -File $q'+"$PSScriptRoot\Sign.ps1"+'$q -Path $f'
    }
    & $IsccPath @options "$PSScriptRoot\PerfectWin11.iss"
    if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
    $fileName=if ($ReleaseSigned) { "PerfectWin11-$version-Setup.exe" } else { "PerfectWin11-$version-UNSIGNED-Setup.exe" }
    $installerInfo=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $artifacts $fileName))
    $binaryVersion='{0}.{1}.{2}.{3}' -f $installerInfo.FileMajorPart,$installerInfo.FileMinorPart,$installerInfo.FileBuildPart,$installerInfo.FilePrivatePart
    if ($binaryVersion -ne "$version.0" -or $installerInfo.ProductName.Trim() -ne 'Perfect Win11' -or $installerInfo.CompanyName.Trim() -ne 'Daniel Salles') {
        throw 'Compiled installer metadata does not match the release identity.'
    }
    if ($ReleaseSigned) {
        & "$PSScriptRoot\Verify-Release.ps1" -Installer "$artifacts\PerfectWin11-$version-Setup.exe" -Payload $payload
    }
} finally { $buildLock.Dispose() }
