# Releasing Perfect Win11

The packaging code is ready for development builds. **There is no accepted signed release or WinGet listing yet.** Signing enrollment, a real signing run, and the disposable Windows 11 checks below must happen first.

## 1. Build locally

Use Windows PowerShell 5.1 from the repository. The launcher uses the installed .NET Framework compiler; users need no extra runtime. Tool versions and download hashes are in `tools.lock.json`. Inno Setup is extracted from the pinned `Tools.InnoSetup` NuGet archive; its compiler signature is verified. Downloading build tools does not install them on your machine.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
# In a PowerShell session with script execution allowed for this process:
$compiler = & .\packaging\Get-BuildTools.ps1
& .\packaging\Build.ps1 -IsccPath $compiler
```

The result is `artifacts\PerfectWin11-0.1.0-UNSIGNED-Setup.exe`. This is a development artifact for your disposable VM, not a release candidate. `-LauncherOnly` builds the payload without fetching or needing Inno Setup. Never run two builds against the same worktree; the build lock enforces that.

The installer adds files, shortcuts, uninstall registration and one user PATH entry. It never starts the setup wizard. In a new terminal after installation:

```powershell
perfect-win11 --help
perfect-win11 --version
perfect-win11 -WhatIf
perfect-win11
perfect-win11 -Resume
perfect-win11 -Reconfigure
perfect-win11 --restore-settings -WhatIf
```

Use a normal, non-elevated account. See [the installer contract](INSTALLER.md) for identity, PATH ownership, operation locking, downgrade rejection, and uninstall details. Uninstall leaves the configured environment and recovery state intact, including the deployed login helper. Disable Win-tap with `-Reconfigure` before uninstalling if you want the helper stopped too.

## 2. Enroll for trusted signing

Daniel supplies the signing account and completes identity verification. Confirm Brazilian individual enrollment and the total certificate/cloud-signing price with SSL.com before purchasing an **IV code-signing certificate with eSigner**. This project does not buy credentials or submit identity documents.

Create the GitHub environment **release-signing** with a required maintainer reviewer. Restrict deployment branches to `main` and protect `main` and release tags from unreviewed changes. The workflow checks for a required-reviewer rule rather than assuming the environment name makes it protected.

Store these environment secrets (never in repository files or issue comments):

| Secret | Value |
| --- | --- |
| `ESIGNER_USERNAME` | SSL.com account username |
| `ESIGNER_PASSWORD` | Account password |
| `ESIGNER_TOTP_SECRET` | eSigner automated-signing TOTP secret |
| `SIGNING_CERT_SHA1` | Exact enrolled code-signing certificate thumbprint |

`Initialize-Signing.ps1` only provisions CKA on an ephemeral GitHub-hosted runner. It uses the pinned SSL.com CKA installer and Windows SDK version in `tools.lock.json`. CKA's upstream installer is hash-pinned from SSL.com's official release; that upstream file is unsigned. The final Perfect Win11 files must still have trusted signatures from your enrolled certificate.

CKA stores its key material on the disposable runner; signing keys stay with the provider. Signing happens only after environment approval, never in pull-request jobs. Provider initialization suppresses normal command output, and credentials come from environment variables. Do not enable shell tracing or publish CKA diagnostic logs, configuration files, or master-key files.

The signer uses SHA-256 and SSL.com's documented RFC3161 timestamp service. Each launcher, PowerShell script/module, installer, and generated uninstaller is signed and verified. Missing credentials, invalid signatures, wrong publishers, absent timestamps, or version mismatches stop the build. There is no unsigned fallback. Signing does not guarantee that SmartScreen reputation warnings disappear.

References: [SSL.com signing service](https://www.ssl.com/products/software-integrity/signing-service/), [official CKA GitHub example](https://github.com/SSLcom/esigner-sample/blob/main/.github/workflows/sign.yml), [SignTool and timestamp instructions](https://www.ssl.com/how-to/using-your-code-signing-certificate/).

## 3. Make a signed candidate

Merge the reviewed packaging code to `main` first. Update `VERSION` for each new candidate; never replace a published artifact or reuse an existing draft's version after code changes. The initial version is `0.1.0`.

```powershell
git tag v0.1.0
git push origin v0.1.0
gh workflow run release.yml --ref main -f tag=v0.1.0
```

The workflow checks that the tag matches `VERSION`, resolves to the checked-out commit, and belongs to `main`. It runs tests, signs the payload, signs setup/uninstall through Inno's signing callback, verifies the release, and creates a **draft** containing:

- `PerfectWin11-0.1.0-Setup.exe`
- `SHA256SUMS` and `release-metadata.json` with the source commit and signer
- `winget-manifests.zip` generated from the final signed installer hash

The workflow does not publish or submit to WinGet. If a workflow fails before creating the draft, it may be retried. Once a candidate draft exists, use a new version for a changed build. Test and publish the same bytes.

## 4. Test the candidate on your disposable VM

Use Windows 11 Home and Pro x64 snapshots with nested virtualization and an ordinary user. Download the draft assets through authenticated GitHub CLI. Compare SHA-256 and Authenticode signer before running anything.

Complete every applicable case in [VALIDATION.md](../VALIDATION.md), including setup, reboot/resume, actual desktop restoration, runtimes/Docker/VS Code, Win taps and native shortcuts. Unit tests do not replace those checks.

Add the following packaging cases and keep logs/screenshots under a dated evidence folder:

| Case | Expected result |
| --- | --- |
| Silent install | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` installs only the tool; no wizard, WSL, desktop, startup-helper or package-state changes. |
| Launch and preview | Start menu opens an interactive console; a fresh terminal finds the command; arrows/Space/Ubuntu input and Ctrl+C behave correctly; `-WhatIf` writes no setup state. Test caller directories with spaces, Unicode and DOS short aliases. |
| Interrupted setup | Cancel a download, close the wizard, install a newer candidate, then resume with state and pinned versions preserved. |
| Reinstall and downgrade | Same-version reinstall works; a lower version is rejected without changing installed files. Use a distinct local test version before testing the final signed version. |
| Uninstall/reinstall | Backups, logs, settings, WSL and deployed helper survive; reinstall restores access to resume/reconfiguration. Unknown user files inside the install directory are not recursively deleted. |
| PATH | Test absent, empty, REG_SZ, REG_EXPAND_SZ, pre-existing tool entry, trailing semicolon, later edits and duplicate entries. Unrelated text/type survives; pre-existing entries are not claimed. |
| Concurrency | Setup/restoration held open blocks install/uninstall; installer open blocks the wizard. No process is killed. Repeat after an owner crashes and while an unowned handle remains. |
| Platform and identity | Elevated launch, Windows 10, ARM64 and Windows Server are rejected; alternate administrator credentials are used only by the wizard's machine operations. |
| Signatures | Installed launcher, scripts/modules, setup and `unins000.exe` all have the expected trusted signature and timestamp. |
| Local WinGet | Validate and install through a test manifest; detect the installed version, reinstall/upgrade, and uninstall correctly. |

Draft assets do not have anonymous public download URLs. For pre-publication WinGet testing, copy the generated manifests to a separate test directory and change **only** their `InstallerUrl` to a temporary HTTP endpoint serving the exact downloaded installer bytes inside your isolated VM network. Keep the hash unchanged. Run `winget validate --manifest <test-directory>`. Enable `LocalManifestFiles` from an elevated terminal in the disposable VM, then perform the install from a normal terminal using `winget install --manifest <test-directory> --scope user --silent`. Never submit those test URLs. After publication, repeat against the unmodified manifests and public release URL.

Copy `acceptance.example.json` into `artifacts\acceptance.json`. Fill in the exact candidate version, installer hash, source commit, tester, ISO test date, and evidence location. Mark a group `passed` only when every case in that group passed on the required VM editions. Update `VALIDATION.md` with the results and candidate hash; a documentation-only evidence commit does not change the candidate's source identity.

## 5. Publish the accepted bytes

Use GitHub CLI authenticated as the maintainer. Set `SIGNING_CERT_SHA1` to the expected public thumbprint and run:

```powershell
& .\packaging\Publish-Release.ps1 -AcceptanceRecord .\artifacts\acceptance.json -WhatIf
& .\packaging\Publish-Release.ps1 -AcceptanceRecord .\artifacts\acceptance.json
```

The preview downloads and verifies the draft but does not publish it. The actual command re-downloads the draft, verifies signature/hash/version/source identity, requires all acceptance groups to be passed, attaches the acceptance record, and publishes without rebuilding. Its local downloads remain under `artifacts` for inspection.

## 6. Submit to WinGet

After publication, download and extract `winget-manifests.zip`, verify the release URL works anonymously, and repeat validation/install on a clean VM with those unmodified manifests. Use the official Manifest Creator to submit:

```powershell
winget validate --manifest .\artifacts\winget
wingetcreate submit .\artifacts\winget
```

Complete GitHub authentication and the contributor agreement when requested. The repository path is `manifests/m/Martoto/PerfectWin11/0.1.0`. The generated package has user scope, native x64 architecture, Windows 11 minimum, MIT license, and the installer's real application identity. Inno's recognized installer type supplies its standard silent switches.

Follow the PR's checks and review comments. Submission is not acceptance. After Microsoft merges and indexes it, verify:

```powershell
winget show --id Martoto.PerfectWin11 -e
winget install --id Martoto.PerfectWin11 -e --scope user
perfect-win11 --version
```

Only then advertise that install command in the README. Future versions repeat the same process; use `winget upgrade --id Martoto.PerfectWin11 -e` once a newer accepted package is available.

References: [manifest creation](https://learn.microsoft.com/en-us/windows/package-manager/package/manifest), [repository submission](https://learn.microsoft.com/en-us/windows/package-manager/package/repository).
