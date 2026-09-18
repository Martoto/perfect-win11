#Requires -Version 5.1
$ErrorActionPreference='Stop'
$errors=@()
# Parse source only: build artifacts can contain downloaded tools and linked fixtures.
$repo=Split-Path $PSScriptRoot
$sourceFiles=@(Get-ChildItem $repo -File -Filter '*.ps1')
foreach ($folder in @('lib','tests','packaging')) {
    $sourceFiles+=@(Get-ChildItem (Join-Path $repo $folder) -Recurse -File | Where-Object Extension -in @('.ps1','.psm1'))
}
$sourceFiles | ForEach-Object {
    $tokens=$null; $parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$parseErrors)
    $errors += $parseErrors
}
if ($errors.Count) { $errors | Format-List | Out-Host; exit 1 }
Import-Module Pester -MinimumVersion 3.4
$result=Invoke-Pester -Script @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' | ForEach-Object { $_.FullName }) -PassThru
if ($result.FailedCount) { exit 1 }
exit 0
