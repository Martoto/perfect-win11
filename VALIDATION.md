# Validation record and VM acceptance checklist

## Packaging work (2026-09-17)

- Windows PowerShell 5.1 / Pester 3.4: **96 passed, 0 failed**. GitHub workflow validation with actionlint 1.7.12 passes; documentation links, Markdown fences, and diff whitespace checked.
- GitHub-hosted Windows build and tests pass after explicitly pinning Pester 3.4 (hosted images also contain incompatible Pester 5). The release-signing environment requires maintainer approval and permits deployment from `main` only; signing secrets are not provisioned.
- The x64 .NET Framework launcher compiles using the Windows Framework compiler. Process tests exercise literal argument forwarding (spaces, quotes, Unicode, URL metacharacters, empty values and trailing backslashes), caller directory, restoration routing, missing files, and exit codes 0/1/3010.
- Inno Setup 6.7.1 compiles an unsigned development installer. Product metadata identifies Perfect Win11 / Daniel Salles / 0.1.0. No installer has been executed against the development host.
- Cross-process locking tests exercise contention, retained handles and abandoned ownership. Signing tests reject unsigned/wrong-signer/untimestamped files and version mismatches; successful trust paths use mocked certificate verification and real PE metadata/hashes.
- **NOT RUN:** real eSigner signing, signed installer/uninstaller checks, installer runtime/PATH/upgrade/uninstall scenarios, interactive packaged console and Ctrl+C checks, VM acceptance, and WinGet installation/submission. Follow [packaging/RELEASE.md](packaging/RELEASE.md) and fill the acceptance record with actual results before publication.

## Local verification (2026-09-10)

- Windows PowerShell 5.1.26100.9168: all PowerShell source files parsed successfully.
- Inbox Pester 3.4: **26 passed, 0 failed**. Manifest boundaries, deduplication, preservation, state round-trips, failure reporting, pinned-version retries, reboot checkpoints and resumable steps exercised with mocked operations.
- `Setup.ps1 -WhatIf` and `-WhatIf -AppList app-list.example.json`: completed successfully, displayed merged defaults.
- No system setup, app removal, elevation, registry changes, runtime installation or Docker execution was performed on the development host.
- WSL enumeration is unavailable in this execution environment (`Wsl/EnumerateDistros/Service/E_ACCESSDENIED`). A disposable Windows 11 VM was not available. Python/AutoHotkey runtime verification and the matrix below remain **NOT RUN**. Do not treat unit-test success as end-to-end certification.

## AutoHotkey startup fix verification

- Reproduced the original line-4 startup error with the installed AutoHotkey **2.0.27** interpreter: `#MenuMaskKey vkE8` is not a recognized v2 action; exit code 2.
- Replaced it with the v2 `A_MenuMaskKey` assignment. Interpreter load-only validation of the corrected helper passes with exit code 0. This check runs without activating hotkeys.
- Disabled InputHook's text collection/1023-character limit with `L0`, keeping shortcut tracking active during long sessions.
- Added helper-content/startup-registration checks on resume and interpreter validation before installation. Physical keyboard and login acceptance checks below still need manual execution.
- Expanded Pester suite: **30 passed, 0 failed**, including stale-helper replacement and missing startup registration.

## Wizard and desktop reconfiguration verification (2026-09-14)

- PowerShell 5.1 parsing passed; **69 Pester tests passed, 0 failed**. Coverage includes the wizard, dependency changes, bulk selection, cancellation, scrolling frames, fallback input, state migration, desktop opt-outs and independent reconfiguration retries.
- Exercised the real console wizard in a Windows pseudo-terminal: Space toggled a desktop setting, Right/Left moved between screens while retaining it, and Esc/Y cancelled. The cursor was restored and the process exited successfully. This used `tests/Preview-Wizard.ps1`; it did not save selections or change desktop settings.
- Rendered narrow and normal-width frames, including the Linux screen. Regression tests check frame dimensions and individual review rows.
- Native enable/restore operations remain mocked. Full Windows Terminal/classic-console manual resize checks and actual desktop restoration on a disposable VM remain **NOT RUN**.

### Additional acceptance cases (NOT RUN)

| Case | Required outcome |
| --- | --- |
| Wizard navigation | Space toggles once, Back/Next retains choices, required items explain their dependencies, build prerequisites expand/collapse. |
| Review and cancellation | Every selected operation is visible by scrolling; Back edits it; Esc/Y or declining APPLY leaves disk and desktop unchanged. |
| Resize and fallback | Test 50x16 and larger layouts in Windows Terminal and the classic console; resizing retains focus; fallback numbers work; redirected input cannot approve changes. |
| Initial desktop opt-outs | Uncheck each new desktop toggle; its associated settings/startup/default-profile changes do not occur. |
| Legacy-state migration | Complete a version-1 run, preview reconfiguration without changing the state file, then approve one setting; original versions, logs and backups survive. |
| Desktop on/off cycles | Toggle all eight settings on, off, then on again. Off restores recorded originals; unrelated JSON/registry values and Terminal profiles survive. |
| Win-tap reconfiguration | Disable only the managed helper. Other AutoHotkey scripts keep running. Re-enable with AutoHotkey initially absent; the disclosed dependency is installed. |
| Failed restoration | Make a backup unavailable or cancel Widgets UAC. Report that setting as failed; preserve other successful changes and retry only unfinished actions on resume. |

## Original disposable VM matrix (all NOT RUN)

Use a fresh Windows 11 Home x64 VM and repeat on Pro x64. Enable nested virtualization. Take an OOBE-completed, signed-in snapshot; transfer this project to the normal user's local disk. Record OS/WSL/WinGet/PowerToys versions and preserve transcripts, state, screenshots and outputs for each case.

| Case | Procedure | Required outcome |
| --- | --- | --- |
| Fresh install | Accept defaults in normal PowerShell 5.1; approve UAC. | Per-user settings/WSL belong to initiating user; selected apps removed and packages installed. |
| Missing WinGet | Start from a snapshot without registered App Installer. | Supported registration or Microsoft.WinGet.Client repair succeeds for initiating user. |
| Reboot/resume | Apply with disabled WSL features; rerun before reboot, then reboot and resume. | No automatic reboot; 3010 and command displayed; before-reboot resume pauses; after reboot progresses. |
| Idempotence | Run again after completion. | No duplicate Bash blocks, Terminal profiles or startup entries; no repeated removals/installations of satisfied packages. |
| Interrupted run | Close setup during a download; resume. | Saved running step retried; earlier success preserved; same pinned version used. |
| Failed package | Select valid but nonexistent WinGet/APT IDs. | Each failure named; other packages continue; nonzero result; resume retries failures. |
| Network failure | Disable network before setup, then during package install. | Preflight stops early; later failures retain usable state; restoring network and resuming works. |
| No virtualization | Disable VM nesting/firmware virtualization. | Stops before mutations with actionable message. |
| Existing Ubuntu | Install Ubuntu 24.04 with sentinel files and custom configs; explicitly reuse. | Files survive, config keys survive, normal default user stays, only selected distro restarted. |
| Declined reuse | Decline reuse when Ubuntu-24.04 already exists. | Stops; never resets/unregisters it. |
| Existing Docker | Preinstall docker.io/containerd with a sentinel container. | Reports migration requirement; no conflicting-package removal or container deletion. |
| Existing configuration | Add Terminal JSONC comments, profile defaults, custom profiles and a PowerToys hotkey. | Unknown parsed settings survive; originals backed up; only intended values change. |
| Cancelled UAC | Cancel a feature/provisioning prompt. | Step reports failure and remains resumable. |
| Alternate admin credentials | Run coordinator as a standard desktop user, elevate with another admin. | Only feature/provisioning work uses admin account; HKCU settings and distro stay with desktop user. |
| Bad manifests | Try HTTP, commands, repo fields, whitespace/options, invalid schema and malformed JSON. | Rejected before state or machine changes. |
| WhatIf | Snapshot filesystem/registry, preview default and custom manifest. | No local writes, app downloads, elevation, distro starts or shell changes. |
| Settings restore | Preview and execute restore after closing affected apps. | Saved settings return; removed apps/data not claimed restored; unrelated registry values remain. |

## Runtime and integration acceptance (NOT RUN)

In a new Ubuntu shell:

```bash
systemctl is-system-running
node --version
python --version
go version
rustc --version
cargo --version
ruby --version
mise ls
starship --version
zoxide --version
git --version
gh --version
nvim --version
tmux -V
rg --version
fd --version
fzf --version
bat --version
jq --version
btop --version
docker run --rm hello-world
docker compose version
docker buildx version
```

Check runtime outputs against saved resolved versions. All five runtimes must execute as the normal user. `hello-world` must work without sudo. `systemctl is-system-running` may report a degraded WSL system; inspect `systemctl --failed` and require Docker to be active and enabled. Record individual failures.

Open Windows Terminal and confirm its default profile starts the selected Ubuntu distro in the Linux user's home. From that shell, run `code .`; allow VS Code Server download and confirm the remote indicator shows **WSL: selected distro**. Create a Linux file in the editor and read it in the terminal. Extension installation alone does not establish that the connection works.

## Desktop/manual acceptance (NOT RUN)

1. Tap left Win and right Win independently at 100 ms, 250 ms and near 300 ms. Command Palette opens; Start must not flash. Repeated taps should remain responsive.
2. Hold each Win for over 300 ms without another key. It must not count as a palette tap. Verify native release behavior and no stuck modifier.
3. Verify Win+E, Win+R, Win+L (unlock afterward), Win+Tab, Win+arrows, Win+Shift+S, key repeats and both key-release orders. No unintended palette opens.
4. Test a modifier already held before Win, both Win keys together, Win plus mouse buttons/wheel, and hotkeys in elevated applications. Verify held-state behavior after locking/unlocking and sleep/resume.
5. Exit the helper from its tray. Win returns to native behavior. Start it again from the state directory using AutoHotkey v2; verify no duplicate instance.
6. Verify taskbar auto-hide on primary and secondary monitors and that other taskbar flags remain unchanged.
7. Sign out/in. Confirm PowerToys and helper start once, Command Palette works, taskbar behavior persists, Widgets entry is hidden and Search stops returning web suggestions where supported by that Windows build.

Do not mark the release accepted until the matrix and manual cases have recorded results and any failures are fixed.
