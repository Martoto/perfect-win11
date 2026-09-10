#Requires -Version 5.1
$ErrorActionPreference='Stop'
$errors=@()
Get-ChildItem "$PSScriptRoot\.." -Recurse -Include *.ps1,*.psm1 | ForEach-Object {
    $tokens=$null; $parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$parseErrors)
    $errors += $parseErrors
}
if ($errors.Count) { $errors | Format-List | Out-Host; exit 1 }
Import-Module Pester -MinimumVersion 3.4
$result=Invoke-Pester -Script "$PSScriptRoot\Core.Tests.ps1" -PassThru
if ($result.FailedCount) { exit 1 }
exit 0
