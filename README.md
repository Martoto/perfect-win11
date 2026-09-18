# Perfect Win11

[![Contributors](https://img.shields.io/github/contributors/Martoto/perfect-win11?style=flat-square&color=8b5cf6)](https://github.com/Martoto/perfect-win11/graphs/contributors)
[![Stars](https://img.shields.io/github/stars/Martoto/perfect-win11?style=flat-square&color=f59e0b)](https://github.com/Martoto/perfect-win11/stargazers)
[![Issues](https://img.shields.io/github/issues/Martoto/perfect-win11?style=flat-square&color=ef4444)](https://github.com/Martoto/perfect-win11/issues)
[![Last commit](https://img.shields.io/github/last-commit/Martoto/perfect-win11?style=flat-square&color=22c55e)](https://github.com/Martoto/perfect-win11/commits/main)
[![Windows 11 x64](https://img.shields.io/badge/Windows-11%20x64-0078D4?style=flat-square)](#run-it)
[![Windows PowerShell 5.1](https://img.shields.io/badge/Windows%20PowerShell-5.1-5391FE?style=flat-square)](#run-it)
[![License: MIT](https://img.shields.io/badge/license-MIT-22c55e?style=flat-square)](LICENSE)

I Actually believe Win11 can be as good of a developer desktop experience as linux or Mac. So I built this opinionated configuration tool to get OOBE windows into a respectable shape.

Larpers beware!

The idea is pretty simple: less junk on the desktop, a proper Linux dev environment underneath, and fewer reasons to reach for the mouse. Pick what you want in the terminal, review the changes, and let it handle the boring parts.

## Run it

Working on a proper installer and WinGet package too. They're not released yet; [the release checklist](packaging/RELEASE.md) tracks what's left to test. For now, run from this repo as shown below.

Start after Windows has finished its first-run setup and you've signed in. You'll need Windows 11 x64 Home or Pro, internet, administrator credentials, and virtualization enabled in your firmware. In a VM, that means nested virtualization too.

Open **64-bit Windows PowerShell 5.1 as your normal user**, not as administrator. Setup asks for UAC when it needs it. From this repository's directory:

```powershell
# Have a look before changing anything:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 -WhatIf

# Pick your setup and get going:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1

# Bring your own extra packages:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 -AppList .\app-list.example.json

# Pick up after a restart or a failed install:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 -Resume

# Change desktop settings once setup is finished:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 -Reconfigure
```

`ExecutionPolicy Bypass` only applies to that PowerShell process. Keep the repo where it is until setup finishes.

### Picking what you want

The wizard walks through Desktop, Distractions, App removal, Windows apps, Linux tools, and a final Review. No memorizing package names just to tick a box.

| Key | What it does |
| --- | --- |
| Up / Down | Move through the list |
| Space | Toggle a choice |
| Left / Right | Back / Next |
| Enter | Activate the selected action |
| Home / End | Jump to the first / last row |
| Esc | Ask to cancel without saving |

Each screen has bulk selection and recommended defaults. The description below the list tells you what a feature does and why it needs another package. Build libraries are tucked into an expandable **Build prerequisites** entry.

PowerToys with Command Palette, Windows Terminal, and Ubuntu/WSL2 are part of the base setup. Other choices can pull in dependencies: Win-tap needs AutoHotkey, for example. To clear a dependency, turn off the feature that needs it first.

If your terminal can't run the full-screen wizard, or is smaller than 50 columns by 16 rows, you get a numbered list instead. Type a number to toggle, or `next`, `back`, or `cancel`. An empty answer doesn't move you forward.

Nothing gets applied until you review it and type `APPLY`. Installing packages accepts their license and source agreements. You may see UAC prompts along the way.

### Something failed, or Windows needs a restart?

Setup saves its progress. It **never restarts Windows for you**. When a restart is needed, do it when you're ready and run the printed resume command. Failed installs are reported individually so you can retry them.

Running setup again also picks up the saved choices, even without `-Resume`. To preview without applying anything, use `-WhatIf`; approving changes needs an interactive terminal. A remote app-list preview downloads the JSON, but doesn't download packages, resolve versions, or run preflight checks.

For scripts checking the exit code: `3010` means a restart is needed, `1` means something failed or is unfinished, and `0` means the selected automated steps completed. The manual checks in [VALIDATION.md](VALIDATION.md) are separate.

## What you get

### A quieter desktop

Promotional apps start checked for removal. OneDrive, Xbox, Teams, Outlook, and Copilot are there if you want them gone, but start unchecked. Store, App Installer, Edge/WebView2, Defender, Windows Update, and essential Windows components are kept out of the removal list.

The catalog takes cues from [Win11Debloat](https://github.com/Raphire/Win11Debloat). It uses explicit package names and native removal commands, rather than pulling in that project's scripts. Appx removal covers your account and provisioning for future accounts; it leaves other existing accounts alone. OneDrive uses its registered WinGet uninstaller.

Ads, suggestions, Widgets, and web results in Search each have their own toggle. Widgets stays installed; the setting hides its taskbar entry and changes the machine policy. That policy needs UAC to change or restore. Sign out and back in to check the result, since Windows builds and editions don't always honor the same settings.

Taskbar auto-hide and PowerToys startup start checked, but you can turn either off. Auto-hide keeps your other taskbar flags intact. Command Palette stays part of the setup even if you don't want PowerToys starting at login.

### Linux where the dev tools live

Ubuntu 24.04 LTS runs on WSL2 with systemd. You'll create your Linux account through Ubuntu's normal first-run flow, then type `exit` to return to setup. Already have a compatible Ubuntu install? You can choose to reuse it. Setup never resets or unregisters a distro. It may upgrade the selected distro from WSL1 to WSL2 and restart it after changing `/etc/wsl.conf`, so save any work running there first.

The defaults include Git, GitHub CLI, Neovim, tmux, ripgrep, fd, fzf, bat, jq, btop, zoxide, and build tools **inside Ubuntu**. Bash gets mise, Starship, and zoxide integration. Ubuntu's `fdfind` and `batcat` get the usual `fd` and `bat` aliases if those names aren't already taken.

mise installs Node LTS and stable Python, Go, Rust, and Ruby through its core backends. Starship comes through mise's Aqua backend. Versions are saved before installation, so a retry uses the same versions. If a pinned release disappears, setup reports it instead of quietly choosing something else. Existing APT and WinGet packages are accepted without forced downgrades.

Docker Engine, Buildx, and Compose come from Docker's Ubuntu repository, with Docker running through systemd. Your Linux user joins the Docker group, which gives it root-equivalent access. If an existing Docker install conflicts, you'll need to sort out that migration yourself; setup doesn't delete containers or volumes.

### Windows bits worth keeping

VS Code with its WSL extension and PowerShell 7 start selected. Ubuntu gets its own Terminal profile, and you choose whether it becomes the default. Existing profiles stay put. Terminal's settings file is backed up, though its comments and formatting get normalized when saved. Close the Terminal Settings editor before applying so it doesn't overwrite the changes.

The optional AutoHotkey v2 helper opens Command Palette when you tap either Win key within 300 ms. Holding Win for shortcuts still passes the key through; holding it alone doesn't count as a tap. The helper starts at login and has a tray exit action. PowerToys needs to be running in the same session for this to work. The helper uses PowerToys' internal show event, which setup checks; a future PowerToys update could require a helper update.

## Changed your mind?

Run `Setup.ps1 -Reconfigure` once the original setup has finished. That brings back the Desktop and Distractions screens: taskbar, Win-tap, PowerToys startup, Terminal default, ads, suggestions, Widgets, and Search web results.

Unchecking something you've already applied **puts its recorded original value back**. That isn't always the same as switching it off: if auto-hide was on before setup, restoring it leaves it on. On a fresh setup, unchecked settings are left alone.

This only changes desktop settings. It doesn't revisit app removals, Linux tools, or runtimes. Enabling Win-tap can install AutoHotkey if it's missing, and the review tells you that. Disabling it stops this project's helper and restores its startup entry, but leaves AutoHotkey installed.

Your other Terminal profiles and later settings edits stay put. Only the relevant registry values, taskbar flag, or JSON property get restored. If a backup is missing, setup reports the problem instead of guessing what used to be there.

Finish any pending setup with `-Resume` first. Reconfiguration saves its own batch of changes, so a failed change can also be retried with `-Resume` without replaying the whole install. Nothing is saved until you approve it. `-Reconfigure -WhatIf` shows the current settings without opening the wizard or writing anything; don't combine `-Reconfigure` with `-Resume` or `-AppList`.

## Bring your own packages

Pass a local JSON file or a direct HTTPS URL to `-AppList`. Extra packages are merged with the built-in choices and duplicates are removed. Start with [the example](app-list.example.json); [the schema](app-list.schema.json) has the format:

```json
{
  "schemaVersion": 1,
  "windows": ["7zip.7zip"],
  "wsl": ["shellcheck", "httpie"]
}
```

Both arrays must be present, but either can be empty. Windows entries are WinGet IDs from the `winget` source; WSL entries are ordinary APT package names. This is a package list, so shell commands, version overrides, switches, custom repositories, and extra fields aren't accepted.

The limits are 200 IDs per array and 128 characters per ID. Duplicate matching ignores case. Remote redirects aren't followed. Bad JSON or an invalid list is rejected before changes; whether a package actually exists gets checked during installation and reported per package. You can't replace the list in the middle of an existing setup.

## Where everything is saved

Windows state, logs, backups, package inventory, and the login helper live in `%LOCALAPPDATA%\PerfectWin11`. Ubuntu keeps its own package progress and configuration backups in `/var/lib/perfect-win11`. Keep both around while you're resuming a setup.

The saved versions help make retries consistent, but they aren't a complete snapshot of upstream package repositories. The official mise installer is downloaded over HTTPS, cached with its hash, and run as your normal Linux user. Custom package-list entries are never evaluated as shell commands.

If you want a completely different set of packages or removals, finish or deliberately abandon the old run and **archive the whole Windows state directory** before starting again. For desktop tweaks, use `-Reconfigure` instead.

<details>
<summary>The state-file details, if you're digging into a failed run</summary>

`state.json` keeps the initiating user's SID, manifest, selections, pinned versions, step results, backups, and removals. State version 2 also records requested/applied desktop settings and reconfiguration history. Version-1 state is migrated in memory and saved only after approval; existing backups and versions are kept. Custom app lists still use schema version 1.

Writes retain the previous atomic revision. A file lock prevents two setup processes from applying changes at once, and setup checks that saved state hasn't changed while you're reviewing it. Interrupted and failed steps are retried; completed non-package steps are skipped. Ordinary setup resume checks installed WinGet packages again.

Linux's per-package state is the source for Linux retries and is copied into Windows state after each Linux phase, including failures. Don't delete it to try to fix an interrupted install.

Network errors, package failures, cancelled UAC prompts, and incompatible existing settings leave a path to resume. Missing firmware virtualization stops setup before changes. If Ubuntu still uses root as its default account, finish normal account creation, set that account as the default, and resume.

</details>

## Putting settings back

For desktop settings, use `-Reconfigure` and uncheck what you want restored. There's also the older bulk Windows settings restore:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Restore-Settings.ps1 -WhatIf
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Restore-Settings.ps1
```

Exit PowerToys, Terminal, and the helper first. This command asks about each setting. **File restoration replaces the entire backed-up file**, including edits you've made since setup, so compare before accepting. Registry restoration only touches recorded values; taskbar restoration preserves the other current flags. Sign out and back in afterward. Resuming the old setup won't reapply settings it has already marked complete; archive its state if you're starting over.

For Linux, look at `backups` in `/var/lib/perfect-win11/state.json`. Each original path points to its saved copy, or `null` if it didn't exist before setup. Compare the files, then restore what you need with `sudo cp --preserve=mode,ownership,timestamps`. If the original was absent, remove only that specific setup-created file. You can also remove the managed Bash block. After restoring `/etc/wsl.conf`, restart only that distro.

To remove Docker-group access, run `sudo gpasswd -d "$USER" docker`, then exit all Linux sessions and reopen them. Runtimes, installed packages, and Docker's service need their own uninstall or service commands.

Restoring settings won't bring back removed apps or their data, restore app provisioning, uninstall your dev tools, or disable WSL. Reinstall apps through the Store or their publisher. For a full rollback, use a VM snapshot or your usual backup.

## Hacking on it

Want to build the installer? See [packaging and releases](packaging/RELEASE.md). No paid signing account needed. Releases can be unsigned for now, with signing available later. We still test the installer in a VM before publishing it.

Found something broken or have a change in mind? [Open an issue](https://github.com/Martoto/perfect-win11/issues) or send a PR. For bugs, include your Windows version, the command you ran, and the relevant log output. Check logs for personal information before posting them.

```powershell
# Run the mocked PowerShell tests:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1

# Check that the helper loads in AutoHotkey v2:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-WinTap.ps1

# Try the wizard without touching your machine or saving choices:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Preview-Wizard.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Preview-Wizard.ps1 -Reconfigure
```

The suite uses the Pester 3.4 that ships with Windows PowerShell 5.1 and mocks system changes. The helper test needs AutoHotkey v2 installed, or a path passed through `-AutoHotkeyPath`; it loads the script without activating hotkeys. Setup runs that check before installing the helper too, and resume updates the helper when its source changes. Neither test runs setup against your machine.

The full disposable Windows 11 VM checks are still pending. [VALIDATION.md](VALIDATION.md) tracks what's been tested and what's left.

If an old helper fails at `#MenuMaskKey`, update the repo and relaunch `assets\WinTap.ahk` with AutoHotkey v2. That directive was replaced with `A_MenuMaskKey := "vkE8"`. For an installed setup, `Setup.ps1 -Resume` updates the saved helper too.

### References

The implementation follows the docs for [WinGet](https://learn.microsoft.com/en-us/windows/package-manager/winget/), [WSL installation](https://learn.microsoft.com/en-us/windows/wsl/install), [systemd in WSL](https://learn.microsoft.com/en-us/windows/wsl/systemd), [mise's core tools](https://mise.jdx.dev/core-tools.html), [installing mise](https://mise.jdx.dev/installing-mise.html), and [Docker on Ubuntu](https://docs.docker.com/engine/install/ubuntu/). The PowerToys integration uses its [module keys](https://github.com/microsoft/PowerToys/blob/main/src/settings-ui/Settings.UI.Library/EnabledModules.cs) and [Command Palette show event](https://github.com/microsoft/PowerToys/blob/main/src/modules/cmdpal/Microsoft.CmdPal.UI/MainWindow.xaml.cs).

OOBE customization, account sign-ins, automatic tiling, and matching desktop themes aren't part of v1. Finish Windows setup first; this takes over from there.
