# Perfect Win11

I Actually believe Win11 can be as good of a developer desktop experience as linux or Mac. So I built this opinionated configuration tool to get OOBE windows into a respectable shape. 

Larpers beware!

## Run

From this directory:

```powershell
# Preview defaults, without installing, writing state, or elevating:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 -WhatIf

# Select apps and apply:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1

# Merge additional packages with the built-in choices:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 -AppList .\app-list.example.json

# Resume after a restart or a failed installation:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 -Resume

# Revisit desktop settings after setup completes:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 -Reconfigure
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 -Reconfigure -WhatIf
```

ExecutionPolicy Bypass applies only to that process. The setup does not change the machine's execution policy. Keep this project in place until setup finishes.

The wizard groups choices into **Desktop**, **Distractions**, **App removal**, **Windows apps**, **Linux tools**, and **Review**. Use **Up/Down** to move, **Space** to toggle, **Left/Right** for Back/Next, and **Enter** to activate a focused action. **Home/End** jump to the first/last row. **Esc** asks whether to cancel; cancellation does not save or apply changes. Details beneath the list explain the focused feature and its dependencies.

Each selection screen offers **Select optional**, **Clear optional**, and **Recommended defaults**. Build libraries appear under an expandable **Build prerequisites** entry. Dependencies update immediately and explain why an item is required; turn off its parent feature before clearing it. PowerToys with Command Palette, Terminal, and Ubuntu/WSL2 remain foundations. AutoHotkey is included when Win-tap is selected, or when explicitly selected as an application.

The full-screen interface requires an interactive console at least 50 columns by 16 rows. Smaller or unsupported hosts use a numbered interface with the same choices and explanations: enter one displayed number, `next`, `back`, or `cancel`. Blank input never accepts a screen. Redirected input can navigate the fallback interface, but it cannot approve system changes; use `-WhatIf` for unattended previews.

Review all changes, go Back if needed, and continue to the explicit `APPLY` prompt. Setup accepts the selected installers' license and source agreements. Installers may display UAC prompts. Execution shows running, completed, skipped and failed steps with the retry command at the end.

The setup never reboots Windows automatically. Exit code `3010` means restart manually and use the printed resume command; `1` means an error or unfinished step; `0` means selected automated steps completed (manual acceptance checks remain). Launching again without `-Resume` also reuses existing saved state. `-AppList` cannot replace an in-progress manifest. Previewing a remote manifest downloads that JSON only; previews do not resolve live versions or run preflight probes.

## What gets configured

- Promotional Appx apps are preselected for removal. OneDrive, Xbox apps, Teams, Outlook and Copilot are optional, initially unchecked. Appx removal affects the initiating user and future-account provisioning, not other existing users. OneDrive uses WinGet's registered uninstall mechanism. No wildcard removal or downloaded debloat scripts are used.
- Store, App Installer, Edge/WebView2, Defender, Windows Update and essential components are excluded. The deliberately small catalog was informed by [Win11Debloat](https://github.com/Raphire/Win11Debloat); it does not import that project's scripts or comprehensive removal list.
- Separate options disable ad personalization/promotional installs, suggestions, Widgets through its machine policy (and hide its taskbar entry), and web search suggestions. Windows may ignore or change registry policies/preferences across builds and editions; sign out/in and verify them. The Widgets package itself stays installed. The original Widgets policy is backed up and restoration requests UAC for it.
- Ubuntu 24.04 LTS runs on WSL2 with systemd. The normal Ubuntu first-run flow creates your Linux account. Type `exit` to return to setup. An existing compatible Ubuntu can be explicitly selected for reuse; setup never unregisters or resets distributions. Reuse may upgrade a WSL1 distribution to WSL2 and restarts only the selected distribution after editing `/etc/wsl.conf`. Save its running work before applying.
- Git, GitHub CLI, Neovim, tmux, ripgrep, fd, fzf, bat, jq, btop, zoxide and build packages are preselected **inside Ubuntu**. Bash aliases expose Ubuntu's `fdfind` and `batcat` as `fd` and `bat` if those names are not already present.
- mise manages Node LTS and stable Python, Go, Rust and Ruby through its core backends. Starship uses mise's Aqua backend. Versions are resolved and checkpointed before installation; an unavailable pinned release fails visibly instead of silently switching versions. Existing installed APT/WinGet packages are accepted without forced downgrades. Observed package versions are saved separately.
- Docker Engine, Buildx and Compose use Docker's Ubuntu repository. Docker starts through systemd. Docker-group membership gives the chosen Linux user root-equivalent access. Conflicting existing Docker/container packages require manual migration; setup does not delete containers or volumes.
- VS Code with the WSL extension and PowerShell 7 are preselected on Windows. Ubuntu receives a dedicated Terminal profile without replacing existing profiles; making it the default is optional. Terminal JSONC comments/formatting are normalized; other parsed values are retained and the original file is backed up. Close Terminal's Settings editor before applying to avoid concurrent edits.
- Taskbar auto-hide and PowerToys startup are separate, initially enabled choices. Auto-hide uses `SHAppBarMessage` and preserves other appbar state flags. Command Palette enablement remains part of setup independently of startup. Other module settings and the existing activation shortcut stay intact.
- The optional Win-tap helper starts at login. A standalone left/right Win tap of at most 300 ms invokes Command Palette's existing show event. Physical Win-down is passed through immediately for native combinations. A held key alone is not a tap. The helper provides a tray exit action. PowerToys must be running in the same session, even if its startup option is unchecked. The show event is an upstream implementation detail checked during setup; future upstream changes may require updating the helper.

## Reconfigure desktop settings

After a successful setup, `-Reconfigure` reopens the Desktop and Distractions screens. It controls taskbar auto-hide, Win-tap, PowerToys startup, Terminal's default profile, ads, suggestions, Widgets and Search web results. It does not change app-removal, Linux, runtime or other package selections. Enabling Win-tap may install its AutoHotkey dependency if missing; this is disclosed in review.

Unchecking a previously applied setting **restores its recorded original values**. If the feature was already enabled before setup, restoring that original value may leave it enabled. On a fresh setup, an unchecked setting is simply left alone.

Restoration touches only the relevant registry values, taskbar flag or JSON property. Changing Terminal's default preserves the dedicated Ubuntu profile and any other profiles or preferences added since setup. Turning off Win-tap stops only the managed helper, restores its startup entry, and leaves AutoHotkey installed. Missing backups cause a specific failure; the tool does not guess factory defaults.

Reconfiguration requires the original setup to be complete. Finish pending or failed setup steps with `-Resume` first. Approved reconfiguration is saved as a separate batch; if a change fails, `-Resume` retries only its unfinished actions. Successful batches remain in history. Changes are not saved until the final approval, including migration from an older state file. `-Reconfigure` cannot be combined with `-Resume` or `-AppList`; `-Reconfigure -WhatIf` displays the current plan without writing or opening the wizard.

## Custom package data

Use [app-list.schema.json](app-list.schema.json) and [app-list.example.json](app-list.example.json):

```json
{
  "schemaVersion": 1,
  "windows": ["7zip.7zip"],
  "wsl": ["shellcheck", "httpie"]
}
```

Both arrays are required and may be empty. Maximum 200 IDs per array and 128 characters per ID. IDs are deduplicated case-insensitively. Only WinGet IDs from the `winget` source and ordinary APT package names are accepted; no shell commands, versions, switches, repositories or extra fields. A local path or direct HTTPS URL is supported; remote redirects are rejected. Syntax is validated before changes; actual package availability is checked at installation and reported per package.

## State, retry and recovery

`%LOCALAPPDATA%\PerfectWin11` contains `state.json`, its previous atomic revision, transcripts, file backups, installed WinGet inventory and the login helper. State version 2 records requested/applied desktop settings and reconfiguration history in addition to the initiating SID, manifest, package choices, pinned versions, step results, backups and removals. Legacy version-1 files are migrated in memory using saved choices and completed steps; existing backups and versions are retained. Custom package manifests still use schema version 1.

A file lock prevents concurrent applying processes, and approval checks for state changes since the review began. `running` and `failed` steps are retried; completed non-package steps are skipped. WinGet packages are inventoried again during ordinary setup resume. For a fresh set of package/removal choices, finish or deliberately abandon the old run and **archive** the whole state directory first. Use `-Reconfigure` for later desktop changes.

Ubuntu also stores atomic per-package state and configuration backups in `/var/lib/perfect-win11`. This is authoritative for Linux retries and is mirrored into Windows state after each Linux phase, including failures. Do not remove it while resuming. Package dependencies may change in upstream repositories; the saved top-level versions are a reproducibility aid, not an offline repository snapshot. The mise installer is downloaded over HTTPS from its official endpoint, cached with its hash, and executed as the normal Linux user. No custom manifest content is evaluated as a shell command.

Network failures, package errors, UAC cancellation and incompatible existing configuration are reported and leave a resume path. If firmware virtualization is unavailable, setup stops before applying. If Ubuntu's default account remains root, finish the distro's normal account initialization, set its normal default user, then resume. If an installer reports a pending restart, restart manually and resume.

For targeted restoration, prefer `-Reconfigure` and uncheck the desired settings. The older bulk **Windows settings** restoration command remains available:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Restore-Settings.ps1 -WhatIf
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Restore-Settings.ps1
```

Exit PowerToys, Terminal and the helper first. Restoration asks per setting. File restoration replaces the whole backed-up file, including edits made since setup; compare the backup before accepting. Registry restoration only touches values recorded by this project. Auto-hide restoration preserves other current appbar flags. Sign out/in afterward. Do not resume an old setup expecting it to reapply completed settings after restoration; archive its state for a new run.

For Linux, inspect the `backups` map in `/var/lib/perfect-win11/state.json`. Each key is the original path and its value is a saved copy (or null if originally absent). Compare and manually restore desired files with `sudo cp --preserve=mode,ownership,timestamps`; remove only the specific setup-created file when its original was absent. Remove the managed Bash block if desired. Restart only that distro after restoring `/etc/wsl.conf`. To revoke Docker membership, use `sudo gpasswd -d "$USER" docker`, then exit all Linux sessions and reopen them. Runtime installations, Docker service enablement and installed packages require their respective uninstall/service commands.

Settings restoration **does not reinstall removed apps, restore their provisioning, recover app/user data, uninstall developer packages or disable WSL features**. Reinstall removed applications through Microsoft Store or their publisher. Keep a VM snapshot or normal machine backup for broader rollback.

## Development

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-WinTap.ps1

# Try the wizard without changing the machine or saving selections:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Preview-Wizard.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Preview-Wizard.ps1 -Reconfigure
```

The suite runs with the inbox Pester 3.4 on Windows PowerShell 5.1 and mocks system operations. The separate AutoHotkey test requires the v2 interpreter (or `-AutoHotkeyPath`) and validates script loading without activating hotkeys. Setup also performs this check before copying/registering the helper. Resume refreshes the helper when its source hash changes. Neither test executes setup against the host. See [VALIDATION.md](VALIDATION.md) for the remaining acceptance procedure.

If an older helper reports an error at `#MenuMaskKey`, update the repository and relaunch `assets\WinTap.ahk` with AutoHotkey v2. The directive was replaced by `A_MenuMaskKey := "vkE8"`. For an installed setup, `Setup.ps1 -Resume` updates the saved helper as well.

Implementation references: [Microsoft WinGet bootstrap](https://learn.microsoft.com/en-us/windows/package-manager/winget/), [WSL installation](https://learn.microsoft.com/en-us/windows/wsl/install), [WSL systemd](https://learn.microsoft.com/en-us/windows/wsl/systemd), [mise core tools](https://mise.jdx.dev/core-tools.html), [mise installation](https://mise.jdx.dev/installing-mise.html), [Docker Ubuntu installation](https://docs.docker.com/engine/install/ubuntu/), [PowerToys enabled-module keys](https://github.com/microsoft/PowerToys/blob/main/src/settings-ui/Settings.UI.Library/EnabledModules.cs), and [Command Palette show-event handler](https://github.com/microsoft/PowerToys/blob/main/src/modules/cmdpal/Microsoft.CmdPal.UI/MainWindow.xaml.cs).

OOBE customization, account sign-ins, automatic tiling and coordinated desktop themes are outside v1.
