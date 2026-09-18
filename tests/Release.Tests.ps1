$originalReleaseThumbprint=$env:SIGNING_CERT_SHA1
$repo=Split-Path $PSScriptRoot
$verify=Join-Path $repo 'packaging\Verify-Release.ps1'
$sign=Join-Path $repo 'packaging\Sign.ps1'
$manifest=Join-Path $repo 'packaging\New-WinGetManifest.ps1'

Describe 'Release trust gates' {
    It 'provides the release verifier' { Test-Path $verify | Should Be $true }
    if (Test-Path $verify) {
        . $verify
        BeforeEach {
            $env:SIGNING_CERT_SHA1='1111111111111111111111111111111111111111'
            Set-Content "$TestDrive\sample.ps1" 'Write-Output hello'
        }
        It 'rejects a genuinely unsigned script' {
            { Assert-ReleaseSignature "$TestDrive\sample.ps1" } | Should Throw
        }
        It 'rejects a trusted signature without a timestamp' {
            Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status='Valid'; SignerCertificate=[pscustomobject]@{Thumbprint=$env:SIGNING_CERT_SHA1}; TimeStamperCertificate=$null } }
            { Assert-ReleaseSignature "$TestDrive\sample.ps1" } | Should Throw
        }
        It 'rejects another trusted publisher' {
            Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status='Valid'; SignerCertificate=[pscustomobject]@{Thumbprint='2222222222222222222222222222222222222222'}; TimeStamperCertificate=[pscustomobject]@{Thumbprint='3333333333333333333333333333333333333333'} } }
            { Assert-ReleaseSignature "$TestDrive\sample.ps1" } | Should Throw
        }
        It 'rejects malformed signer configuration' {
            $env:SIGNING_CERT_SHA1='any publisher'
            { Assert-ReleaseSignature "$TestDrive\sample.ps1" } | Should Throw
        }
        It 'accepts explicitly unsigned files without signing credentials' {
            $env:SIGNING_CERT_SHA1=''
            Mock Get-AuthenticodeSignature { [pscustomobject]@{Status='NotSigned'} }
            { Assert-ReleaseFile -Path "$TestDrive\sample.ps1" -Unsigned } | Should Not Throw
        }
        It 'does not treat broken signatures as unsigned' {
            Mock Get-AuthenticodeSignature { [pscustomobject]@{Status='HashMismatch'} }
            { Assert-ReleaseFile -Path "$TestDrive\sample.ps1" -Unsigned } | Should Throw
        }
        It 'accepts a valid timestamped signature from the configured publisher' {
            Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status='Valid'; SignerCertificate=[pscustomobject]@{Thumbprint=$env:SIGNING_CERT_SHA1;Subject='CN=Test'}; TimeStamperCertificate=[pscustomobject]@{Thumbprint='3333333333333333333333333333333333333333'} } }
            (Assert-ReleaseSignature "$TestDrive\sample.ps1").SignerCertificate.Thumbprint | Should Be $env:SIGNING_CERT_SHA1
        }
        It 'rejects an executable with the wrong version even when its signature is valid' {
            Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status='Valid'; SignerCertificate=[pscustomobject]@{Thumbprint=$env:SIGNING_CERT_SHA1}; TimeStamperCertificate=[pscustomobject]@{Thumbprint='3333333333333333333333333333333333333333'} } }
            { Assert-ReleaseInstaller -Installer "$env:WINDIR\System32\cmd.exe" } | Should Throw
        }
    }
}

Describe 'Manifest generation' {
    It 'provides a manifest generator' { Test-Path $manifest | Should Be $true }
    if (Test-Path $manifest) {
        It 'does not emit a manifest for an unsigned file' {
            Set-Content "$TestDrive\unsigned.exe" 'not signed'
            $env:SIGNING_CERT_SHA1='1111111111111111111111111111111111111111'
            { & $manifest -Installer "$TestDrive\unsigned.exe" -OutputDirectory "$TestDrive\blocked" } | Should Throw
            Test-Path "$TestDrive\blocked\Martoto.PerfectWin11.installer.yaml" | Should Be $false
        }
        It 'writes the real artifact digest and stable package identity' {
            # Only Windows certificate trust is simulated; PE resources, hashing and YAML output are real.
            $env:SIGNING_CERT_SHA1='1111111111111111111111111111111111111111'
            $version=(Get-Content "$repo\VERSION" -Raw).Trim()
            $source='using System.Reflection; [assembly: AssemblyFileVersion("'+$version+'.0")] public class Program { public static void Main() {} }'
            $source | Set-Content "$TestDrive\fixture.cs"
            & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe "/out:$TestDrive\fixture.exe" "$TestDrive\fixture.cs"
            $LASTEXITCODE | Should Be 0
            Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status='Valid'; SignerCertificate=[pscustomobject]@{Thumbprint=$env:SIGNING_CERT_SHA1;Subject='CN=Test'}; TimeStamperCertificate=[pscustomobject]@{Thumbprint='3333333333333333333333333333333333333333'} } }
            & $manifest -Installer "$TestDrive\fixture.exe" -OutputDirectory "$TestDrive\manifests"
            $yaml=Get-Content "$TestDrive\manifests\Martoto.PerfectWin11.installer.yaml" -Raw
            $yaml | Should Match ('InstallerSha256: '+(Get-FileHash "$TestDrive\fixture.exe" -Algorithm SHA256).Hash)
            $yaml | Should Match 'Scope: user'
            $yaml | Should Match 'Architecture: x64'
            $yaml | Should Match ([regex]::Escape("releases/download/v$version/PerfectWin11-$version-Setup.exe"))
            $yaml | Should Match ([regex]::Escape('{7D2A0B15-AD80-4E5E-BBB4-9F28B5C30D19}_is1'))
            @(Get-ChildItem "$TestDrive\manifests" -Filter '*.yaml').Count | Should Be 3
        }
    }
}

Describe 'Signing preflight' {
    It 'provides the signing entry point' { Test-Path $sign | Should Be $true }
    if (Test-Path $sign) {
        It 'signs the temporary PE names supplied by Inno for setup and uninstall' {
            $savedTool=$env:SIGNTOOL_PATH
            try {
                $env:SIGNING_CERT_SHA1='1111111111111111111111111111111111111111'
                $env:SIGNTOOL_PATH="$TestDrive\signtool.ps1"
                'exit 0' | Set-Content $env:SIGNTOOL_PATH
                'using System.Reflection; [assembly: AssemblyProduct("Perfect Win11    ")] public class P { public static void Main() {} }' | Set-Content "$TestDrive\temporary.cs"
                & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe "/out:$TestDrive\uninst.e32.tmp" "$TestDrive\temporary.cs"
                Mock Get-Item { [pscustomobject]@{ HasPrivateKey=$true; NotBefore=(Get-Date).AddDays(-1); NotAfter=(Get-Date).AddDays(1); EnhancedKeyUsageList=@([pscustomobject]@{ObjectId=[pscustomobject]@{Value='1.3.6.1.5.5.7.3.3'}}) } } -ParameterFilter { $LiteralPath -like 'Cert:*' }
                Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status='Valid'; SignerCertificate=[pscustomobject]@{Thumbprint=$env:SIGNING_CERT_SHA1}; TimeStamperCertificate=[pscustomobject]@{Thumbprint='3333333333333333333333333333333333333333'} } } -ParameterFilter { $LiteralPath -like '*.e32.tmp' }
                { & $sign -Path "$TestDrive\uninst.e32.tmp" } | Should Not Throw
            } finally { $env:SIGNTOOL_PATH=$savedTool }
        }
        It 'fails closed without a configured certificate' {
            $saved=$env:SIGNING_CERT_SHA1
            try {
                $env:SIGNING_CERT_SHA1=''
                Set-Content "$TestDrive\sample.ps1" 'Write-Output hello'
                { & $sign -Path "$TestDrive\sample.ps1" } | Should Throw
                (Get-AuthenticodeSignature "$TestDrive\sample.ps1").Status | Should Be 'NotSigned'
            } finally { $env:SIGNING_CERT_SHA1=$saved }
        }
        It 'fails closed when signtool reports a signing failure' {
            $savedTool=$env:SIGNTOOL_PATH
            try {
                $env:SIGNING_CERT_SHA1='1111111111111111111111111111111111111111'
                $env:SIGNTOOL_PATH="$TestDrive\signtool.ps1"
                'exit 1' | Set-Content $env:SIGNTOOL_PATH
                Set-Content "$TestDrive\sample.ps1" 'Write-Output hello'
                Mock Get-Item { [pscustomobject]@{ HasPrivateKey=$true; NotBefore=(Get-Date).AddDays(-1); NotAfter=(Get-Date).AddDays(1); EnhancedKeyUsageList=@([pscustomobject]@{ObjectId=[pscustomobject]@{Value='1.3.6.1.5.5.7.3.3'}}) } } -ParameterFilter { $LiteralPath -like 'Cert:*' }
                { & $sign -Path "$TestDrive\sample.ps1" } | Should Throw
            } finally { $env:SIGNTOOL_PATH=$savedTool }
        }
        It 'rejects an apparent signing success that leaves the file unsigned' {
            $savedTool=$env:SIGNTOOL_PATH
            try {
                $env:SIGNING_CERT_SHA1='1111111111111111111111111111111111111111'
                $env:SIGNTOOL_PATH="$TestDrive\signtool.ps1"
                'exit 0' | Set-Content $env:SIGNTOOL_PATH
                Set-Content "$TestDrive\sample.ps1" 'Write-Output hello'
                Mock Get-Item { [pscustomobject]@{ HasPrivateKey=$true; NotBefore=(Get-Date).AddDays(-1); NotAfter=(Get-Date).AddDays(1); EnhancedKeyUsageList=@([pscustomobject]@{ObjectId=[pscustomobject]@{Value='1.3.6.1.5.5.7.3.3'}}) } } -ParameterFilter { $LiteralPath -like 'Cert:*' }
                { & $sign -Path "$TestDrive\sample.ps1" } | Should Throw
            } finally { $env:SIGNTOOL_PATH=$savedTool }
        }
    }
}

Describe 'Release inventory and metadata' {
    if (Test-Path $verify) {
        # Pester 3 cannot shadow native executables directly.
        function git { & git.exe @args }
        BeforeEach {
            $env:SIGNING_CERT_SHA1='1111111111111111111111111111111111111111'
            $version=(Get-Content "$repo\VERSION" -Raw).Trim()
            [void][IO.Directory]::CreateDirectory("$TestDrive\payload\lib")
            $source='using System.Reflection; [assembly: AssemblyFileVersion("'+$version+'.0")] public class Program { public static void Main() {} }'
            $source | Set-Content "$TestDrive\release.cs"
            & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe "/out:$TestDrive\payload\perfect-win11.exe" "$TestDrive\release.cs"
            Copy-Item "$TestDrive\payload\perfect-win11.exe" "$TestDrive\installer.exe"
            $version | Set-Content "$TestDrive\payload\VERSION"
            'Write-Output hello' | Set-Content "$TestDrive\payload\Setup.ps1"
            'Write-Output restore' | Set-Content "$TestDrive\payload\Restore-Settings.ps1"
            'function Test-Example {}' | Set-Content "$TestDrive\payload\lib\Example.psm1"
            Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status='Valid'; SignerCertificate=[pscustomobject]@{Thumbprint=$env:SIGNING_CERT_SHA1;Subject='CN=Test'}; TimeStamperCertificate=[pscustomobject]@{Thumbprint='3333333333333333333333333333333333333333'} } }
            Mock git {
                $global:LASTEXITCODE=0
                if ($args -contains 'rev-parse') { 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
            }
        }
        It 'writes hashes and source identity only after checking the full release' {
            & $verify -Installer "$TestDrive\installer.exe" -Payload "$TestDrive\payload" -OutputDirectory "$TestDrive\verified"
            $metadata=Get-Content "$TestDrive\verified\release-metadata.json" -Raw | ConvertFrom-Json
            $metadata.sourceCommit | Should Be 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            $metadata.verifiedPayloadFiles | Should Be 4
            $metadata.sha256 | Should Be (Get-FileHash "$TestDrive\installer.exe" -Algorithm SHA256).Hash
            (Get-Content "$TestDrive\verified\SHA256SUMS") | Should Match '  installer.exe$'
        }
        It 'verifies and generates manifests for an explicitly unsigned candidate without credentials' {
            $env:SIGNING_CERT_SHA1=''
            Mock Get-AuthenticodeSignature { [pscustomobject]@{Status='NotSigned'} }
            & $verify -Installer "$TestDrive\installer.exe" -Payload "$TestDrive\payload" -OutputDirectory "$TestDrive\unsigned-release" -Unsigned
            $metadata=Get-Content "$TestDrive\unsigned-release\release-metadata.json" -Raw | ConvertFrom-Json
            $metadata.signingMode | Should Be 'unsigned'
            $metadata.signerThumbprint | Should BeNullOrEmpty
            & $manifest -Installer "$TestDrive\installer.exe" -OutputDirectory "$TestDrive\unsigned-manifests" -Unsigned
            (Get-Content "$TestDrive\unsigned-manifests\Martoto.PerfectWin11.installer.yaml" -Raw) | Should Match $metadata.sha256
        }
        It 'rejects an unsigned nested payload module before emitting metadata' {
            Mock Get-AuthenticodeSignature { [pscustomobject]@{Status='NotSigned';SignerCertificate=$null;TimeStamperCertificate=$null} } -ParameterFilter { $LiteralPath -like '*.psm1' }
            { & $verify -Installer "$TestDrive\installer.exe" -Payload "$TestDrive\payload" -OutputDirectory "$TestDrive\rejected" } | Should Throw
            Test-Path "$TestDrive\rejected\release-metadata.json" | Should Be $false
        }
        It 'rejects releases from dirty source checkouts' {
            Mock git {
                $global:LASTEXITCODE=0
                if ($args -contains 'rev-parse') { 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' } else { ' M Setup.ps1' }
            }
            { & $verify -Installer "$TestDrive\installer.exe" -Payload "$TestDrive\payload" -OutputDirectory "$TestDrive\dirty" } | Should Throw
            Test-Path "$TestDrive\dirty\SHA256SUMS" | Should Be $false
        }
    }
}
$env:SIGNING_CERT_SHA1=$originalReleaseThumbprint
