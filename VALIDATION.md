# Validation record and VM acceptance checklist

## Local verification (2026-09-10)

- Windows PowerShell 5.1.26100.9168: all PowerShell source files parsed successfully.
- Inbox Pester 3.4: **26 passed, 0 failed**. Manifest boundaries, deduplication, preservation, state round-trips, failure reporting, pinned-version retries, reboot checkpoints and resumable steps exercised with mocked operations.
- `Setup.ps1 -WhatIf` and `-WhatIf -AppList app-list.example.json`: completed successfully, displayed merged defaults.
- No system setup, app removal, elevation, registry changes, runtime installation or Docker execution was performed on the development host.
- WSL enumeration is unavailable in this execution environment (`Wsl/EnumerateDistros/Service/E_ACCESSDENIED`). A disposable Windows 11 VM was not available. Python/AutoHotkey runtime verification and the matrix below remain **NOT RUN**. Do not treat unit-test success as end-to-end certification.

## Disposable VM matrix (all NOT RUN)

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
