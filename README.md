# Force Delete - Context Menu

Adds a **Force Delete** option to the Windows right-click context menu that can forcefully and instantly delete files and folders — even if they are locked by other processes, owned by SYSTEM, or otherwise undeletable.

<div align="center">
  <img src="https://github.com/user-attachments/assets/02328cfb-7fec-42a3-b9f2-898400f7a6c6" alt="Force Delete in Context Menu" height="380" />
  &nbsp;&nbsp;
  <img src="https://github.com/user-attachments/assets/6d21aacf-9c9d-4d03-842c-026eb91924a1" alt="Force Delete Installer" height="380" />
</div>

## Features

- **Instant deletion** of files and locked folders without scheduling or nagging
- **Robocopy Mirror Purge** engine to obliterate stubborn, corrupted, or deep folders instantly
- **Automatic lock termination** — finds locking processes via Restart Manager and kills them immediately
- **Nuclear permission reset** — takes ownership and grants full control to Everyone, Administrators, and User
- **Extended Path (`\\?\`) support** — deletes paths exceeding 260 characters or reserved Windows names
- **Single confirmation prompt** — confirms once, then deletes immediately without secondary prompts
- **Windows 11 support** — option to enable classic context menu so the entry appears directly
- **Clean install/uninstall** — removes old broken entries from previous versions
- **No dependencies** — pure PowerShell, no Python or external runtimes needed

## Installation & Usage

### Option 1: All-in-One Single Executable (Recommended)
- Download **`ForceDelete-Setup.exe`** from the latest release.
- Double-click to install. It is a completely self-contained single executable that automatically detects your architecture (`x64`, `ARM64`, or `x86`), deploys the native binary to `C:\Program Files\ForceDelete`, and sets up the context menu with the UAC shield.
- To uninstall, run **`Uninstall-ForceDelete.exe`** (or uninstall from Windows Settings > Installed Apps).

### Option 2: Script / Portable Mode (From Source)
1. **Install**:
   - Double-click **`Install_Add-Force-context-menu.bat`** (it will request Administrator permissions).
   - Follow the prompt to choose your context menu style (Classic or Modern).
   - The **Force Delete** option with the Windows Security UAC Shield will be added immediately.

2. **Uninstall**:
   - Double-click **`Uninstall_Force-context-menu.bat`**.
   - Removes all context menu entries cleanly.

## Building Standalone Executables

To build the standalone `.exe` packages locally:
```powershell
.\build.ps1
```
This generates the following files in the `dist/` directory:
- `ForceDelete-Setup.exe` (All-in-one single-file installer bundling all binaries and tools)
- `ForceDelete-Package.zip` (Complete archive of all executables and scripts)
- `ForceDelete-x64.exe` (Standalone 64-bit binary)
- `ForceDelete-x86.exe` (Standalone 32-bit binary)
- `ForceDelete-arm64.exe` (Standalone ARM64 binary)
- `Uninstall-ForceDelete.exe` (Single-file self-contained uninstaller)

An automated GitHub Actions workflow (`.github/workflows/release.yml`) builds and releases these assets automatically on every push or manual trigger.

## Windows 11 Note

On Windows 11, custom context menu entries appear under **"Show more options"** by default. During installation, you will be asked if you want to enable the classic full context menu, which makes "Force Delete" appear directly on right-click.

You can revert this change at any time using the uninstall script.

## How It Works

When you click "Force Delete":

1. **Confirms once** that you want to delete the file or folder
2. **Resets attributes & takes ownership** (`attrib -r -s -h`, `takeown /r`, `icacls` granting Everyone, Administrators, and Current User full control)
3. **Scans for locking processes** (passing the folder itself and its contents to Windows Restart Manager API)
4. **Kills locking processes automatically** (releases Explorer folder locks, taskkill, and gsudo fallback)
5. **Applies multi-engine instant wipe**:
   - Direct .NET File / Directory Delete
   - **Robocopy Mirror Purge** (mirrors an empty directory to obliterate locked contents)
   - Extended Path (`\\?\`) command-line RD / DEL (bypasses MAX_PATH and reserved names)
   - Fully elevated `gsudo` wipe (if installed)
6. **Deletes immediately** — no reboot scheduling dialogs!

## Disclaimer

**Use at your own risk!** This tool can delete system files and files locked by critical processes. Be careful what you force-delete — this action cannot be undone.

## Upgrading from Old Version

If you had the old Python-based "Force Delete" installed (the one that no longer works), the install script will **automatically remove the old broken entries** before adding the new ones. No manual cleanup needed!
