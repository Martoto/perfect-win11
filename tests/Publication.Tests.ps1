$repo=Split-Path $PSScriptRoot
Describe 'Publication acceptance gate' {
    It 'rejects pending VM results and a mismatched artifact' {
        . "$repo\packaging\Publish-Release.ps1"
        $record=Get-Content "$repo\packaging\acceptance.example.json" -Raw | ConvertFrom-Json
        { Assert-ReleaseAcceptance $record '0.1.0' ('A'*64) ('b'*40) } | Should Throw
        $record.version='0.1.0'; $record.installerSha256='A'*64; $record.sourceCommit='b'*40
        $record.testedBy='VM tester'; $record.testedAt='2026-09-17T12:00:00Z'
        $record.evidence='VALIDATION.md acceptance record'
        foreach ($property in $record.results.PSObject.Properties) { $property.Value='passed' }
        { Assert-ReleaseAcceptance $record '0.1.0' ('A'*64) ('b'*40) } | Should Not Throw
        { Assert-ReleaseAcceptance $record '0.1.0' ('C'*64) ('b'*40) } | Should Throw
        $record.results.keyboardAndLogin='pending'
        { Assert-ReleaseAcceptance $record '0.1.0' ('A'*64) ('b'*40) } | Should Throw
    }
    It 'previews without publication, then publishes only the verified draft bytes' {
        function gh { throw 'Unexpected unmocked GitHub call.' }
        $oldSigner=$env:SIGNING_CERT_SHA1
        $env:SIGNING_CERT_SHA1='1111111111111111111111111111111111111111'
        $version=(Get-Content "$repo\VERSION" -Raw).Trim()
        ('using System.Reflection; [assembly: AssemblyFileVersion("'+$version+'.0")] public class P { public static void Main() {} }') | Set-Content "$TestDrive\publish.cs"
        & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe "/out:$TestDrive\installer.exe" "$TestDrive\publish.cs"
        $hash=(Get-FileHash "$TestDrive\installer.exe" -Algorithm SHA256).Hash
        $record=Get-Content "$repo\packaging\acceptance.example.json" -Raw | ConvertFrom-Json
        $record.version=$version; $record.installerSha256=$hash; $record.sourceCommit='b'*40
        $record.testedBy='VM tester'; $record.testedAt='2026-09-17T12:00:00Z'; $record.evidence='VM evidence'
        foreach ($property in $record.results.PSObject.Properties) { $property.Value='passed' }
        $record | ConvertTo-Json | Set-Content "$TestDrive\acceptance.json"
        $global:PW11PublishFixture=@{file="$TestDrive\installer.exe";version=$version;hash=$hash;calls=(New-Object Collections.ArrayList)}
        try {
            Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status='Valid'; SignerCertificate=[pscustomobject]@{Thumbprint=$env:SIGNING_CERT_SHA1}; TimeStamperCertificate=[pscustomobject]@{Thumbprint='3333333333333333333333333333333333333333'} } }
            Mock gh {
                $global:LASTEXITCODE=0
                [void]$global:PW11PublishFixture.calls.Add(($args -join ' '))
                if ($args[0] -eq 'api') { return ('b'*40) }
                if ($args[1] -eq 'view') { return '{"isDraft":true}' }
                if ($args[1] -eq 'download') {
                    $directory=$args[([array]::IndexOf($args,'--dir')+1)]
                    Copy-Item $global:PW11PublishFixture.file (Join-Path $directory ('PerfectWin11-'+$global:PW11PublishFixture.version+'-Setup.exe')) -WhatIf:$false
                    @{version=$global:PW11PublishFixture.version;sha256=$global:PW11PublishFixture.hash;sourceCommit=('b'*40);signerThumbprint=$env:SIGNING_CERT_SHA1} | ConvertTo-Json | Set-Content (Join-Path $directory 'release-metadata.json') -WhatIf:$false
                }
            }
            & "$repo\packaging\Publish-Release.ps1" -AcceptanceRecord "$TestDrive\acceptance.json" -WhatIf
            @($global:PW11PublishFixture.calls | Where-Object { $_ -match '^release (upload|edit)' }).Count | Should Be 0
            & "$repo\packaging\Publish-Release.ps1" -AcceptanceRecord "$TestDrive\acceptance.json"
            @($global:PW11PublishFixture.calls | Where-Object { $_ -match '^release upload' }).Count | Should Be 1
            @($global:PW11PublishFixture.calls | Where-Object { $_ -match '^release edit .*--draft=false' }).Count | Should Be 1
        } finally { Remove-Variable PW11PublishFixture -Scope Global; $env:SIGNING_CERT_SHA1=$oldSigner }
    }
}
