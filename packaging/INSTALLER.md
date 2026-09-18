# Installer contract

`PerfectWin11.iss` targets the pinned Inno Setup 6 compiler used by the package build. Supply `/DAppVersion=0.1.0`, `/DPayloadDir=<absolute payload directory>`, and `/DOutputDir=<absolute output directory>`. The payload must contain `perfect-win11.exe` at its root. This script only packages files, shortcuts, uninstall registration, and a user PATH entry; it never runs the setup wizard or a system configuration command.

Unsigned development builds are named `PerfectWin11-<version>-UNSIGNED-Setup.exe`. Release builds require `/DReleaseSigned` and an externally configured named Inno sign tool, `/Sesigner=<signing command>`. Both setup and the generated uninstaller are signed in release mode. The build pipeline must validate the resulting signatures; defining the release symbol alone is not signature verification.

## Identity and location

- Stable AppId: `{7D2A0B15-AD80-4E5E-BBB4-9F28B5C30D19}`.
- Fixed per-user directory: `%LOCALAPPDATA%\Programs\PerfectWin11`.
- Windows 11 workstation, native x64 only. ARM64 and Windows Server are rejected.
- `PrivilegesRequired=lowest`; an elevated setup or uninstall process is explicitly rejected. Run as the intended ordinary user.
- Changing the directory with `/DIR` or a saved setup configuration is rejected before installation writes. Upgrades and reinstalls use the same directory and uninstall identity.
- Existing uninstall `DisplayVersion` is compared numerically; a newer installed version blocks setup. An unreadable version also blocks setup.

## Shared operation lock

Setup and uninstall acquire a Windows mutex in their initialization event and release it during deinitialization. The PowerShell entry points acquire the same mutex before loading application modules and release it on exit. The launcher waits for its PowerShell child, which owns the operation lock:

```text
Global\PerfectWin11.Package.<lowercase LOCALAPPDATA with every backslash and colon replaced by underscore>
```

For example, `C:\Users\Alice\AppData\Local` becomes `Global\PerfectWin11.Package.c__users_alice_appdata_local`. Creation requests initial ownership. If the object already exists, a zero-timeout wait must acquire it; an abandoned mutex is also accepted. An existing handle alone does not mean a live operation owns the lock. Lock failures stop the operation; there is no check-then-create race. No process is terminated to acquire the lock.

The installer disables Restart Manager application closure/restart and rejects the corresponding force/close command-line overrides. Files used by unrelated processes can still cause installation or uninstall to fail; users must close those processes themselves.

## PATH ownership

Only `HKCU\Environment\Path` is changed. Existing `REG_SZ` and `REG_EXPAND_SZ` types are retained. Unsupported types fail safely. The existing raw text is not expanded, normalized, split and rejoined, or reordered. Case-insensitive matching tolerates surrounding whitespace, quotes, and a trailing backslash when checking whether the install directory is already present.

If the entry already exists, setup does not claim it. Otherwise it appends the install directory and persists the raw before/after strings and ownership under `HKCU\Software\PerfectWin11\Package`. Reinstall and upgrade retain the ownership marker when the entry still exists. Uninstall restores the exact original value when the current value still matches the saved after-image, including removing an originally absent value. If PATH has since changed, uninstall removes one exact owned token and the preceding separator only if setup originally inserted that separator. Separators added after the token by another actor are retained, even if removal leaves an empty component. A changed or duplicated token is ambiguous and is preserved. The current registry string type is preserved even if the user changed it after installation.

Uninstall only removes tracked package files, shortcuts, registration, and owned PATH bookkeeping. It does not remove external logs, backups, user settings, wizard results, or any login helper created outside the package. There are no wildcard uninstall-delete rules.

## Silent operations and validation

Use `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` for automated install and uninstall. Check the process exit code and log output; silent mode does not bypass any guard. The install directory contains Inno's `unins000.exe` (the numeric suffix may vary for existing installations).

Validate in a disposable Windows 11 x64 user profile:

1. Clean install, shortcut and `perfect-win11 --help`, uninstall registration, and silent uninstall.
2. Reinstall, upgrade, then attempted downgrade. Verify one install location and retained PATH ownership.
3. PATH initially absent, empty, `REG_SZ`, `REG_EXPAND_SZ`, ending in a semicolon, already containing the directory, and edited after install. Verify exact unrelated contents and registry type after uninstall.
4. Hold the shared mutex in a command; both setup and uninstall must fail without terminating it. Release ownership while retaining a handle; retry must succeed. Repeat with an abandoned mutex.
5. Reject elevated execution, ARM64, Windows 10, Windows Server, alternate `/DIR`, and application-closing overrides.
6. Create representative external backups, logs, and login helper files; verify they survive uninstall.
7. Verify release setup and uninstaller Authenticode signatures against the expected publisher.

Relevant compiler references: [architecture restrictions](https://jrsoftware.org/ishelp/topic_setup_architecturesallowed.htm), [administrative privilege detection](https://jrsoftware.org/ishelp/topic_isxfunc_isadmin.htm), [Windows version fields](https://jrsoftware.org/ishelp/topic_isxfunc_getwindowsversionex.htm), and [application-closing behavior](https://jrsoftware.org/ishelp/topic_setup_closeapplications.htm).
