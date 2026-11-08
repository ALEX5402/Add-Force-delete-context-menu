<#
.SYNOPSIS
    Force Delete - Forcefully and INSTANTLY deletes any file or folder.

.DESCRIPTION
    1. Resets attributes (ReadOnly, System, Hidden)
    2. Takes full ownership and resets permissions (Everyone, Administrators, Current User)
    3. Finds ALL locking processes using Windows Restart Manager API (including the directory itself)
    4. Automatically kills all locking processes without nagging
    5. Releases Explorer directory locks if needed
    6. Multi-engine instant wipe:
       - Direct .NET Directory/File Delete
       - Robocopy Empty Mirror Purge (obliterates locked/nested directories instantly)
       - Extended-length Path (\\?\) RD / DEL
       - Elevated gsudo wipe
    7. No annoying "schedule on reboot" prompt - deletes immediately!
#>

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path
)

# ── Load Windows Forms for dialogs ──
Add-Type -AssemblyName System.Windows.Forms

# ── Ensure running as Administrator ──
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    $scriptPath = $MyInvocation.MyCommand.Definition
    try {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" `"$Path`"" -Verb RunAs
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Administrator elevation was canceled or failed.`nPlease run as administrator.",
            "Force Delete - Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    exit
}

# ── C# FileUnlocker (Restart Manager API + MoveFileEx) ──
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class FileUnlocker
{
    public const int MOVEFILE_DELAY_UNTIL_REBOOT = 0x4;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);

    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS
    {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    const int RmRebootReasonNone = 0;
    const int CCH_RM_MAX_APP_NAME = 255;
    const int CCH_RM_MAX_SVC_NAME = 63;

    enum RM_APP_TYPE { RmUnknownApp = 0, RmMainWindow = 1, RmOtherWindow = 2, RmService = 3, RmExplorer = 4, RmConsole = 5, RmCritical = 1000 }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO
    {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)] public string strServiceShortName;
        public RM_APP_TYPE ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);

    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
        uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);

    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo,
        [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

    public static List<int> GetLockingProcessIds(string[] paths)
    {
        var pids = new List<int>();
        if (paths == null || paths.Length == 0) return pids;

        uint sessionHandle;
        string sessionKey = Guid.NewGuid().ToString();

        if (RmStartSession(out sessionHandle, 0, sessionKey) != 0) return pids;

        try
        {
            if (RmRegisterResources(sessionHandle, (uint)paths.Length, paths, 0, null, 0, null) != 0) return pids;

            uint pnProcInfoNeeded = 0, pnProcInfo = 0, lpdwRebootReasons = RmRebootReasonNone;
            int res = RmGetList(sessionHandle, out pnProcInfoNeeded, ref pnProcInfo, null, ref lpdwRebootReasons);

            if (res == 0 && pnProcInfoNeeded == 0) return pids;

            pnProcInfo = pnProcInfoNeeded;
            var processInfo = new RM_PROCESS_INFO[pnProcInfo];
            res = RmGetList(sessionHandle, out pnProcInfoNeeded, ref pnProcInfo, processInfo, ref lpdwRebootReasons);

            if (res == 0)
            {
                for (int i = 0; i < pnProcInfo; i++)
                {
                    try
                    {
                        Process.GetProcessById(processInfo[i].Process.dwProcessId);
                        pids.Add(processInfo[i].Process.dwProcessId);
                    }
                    catch { }
                }
            }
        }
        finally
        {
            RmEndSession(sessionHandle);
        }

        return pids;
    }
}
"@ -ErrorAction SilentlyContinue

# ── Validate and resolve path ──
$resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)

if (-not (Test-Path -LiteralPath $resolved)) {
    [System.Windows.Forms.MessageBox]::Show(
        "The specified path does not exist:`n$resolved",
        "Force Delete - Not Found",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

# ── Confirmation Dialog (Single confirmation) ──
$itemName = Split-Path $resolved -Leaf
$isDir = (Get-Item -LiteralPath $resolved -Force) -is [System.IO.DirectoryInfo]
$itemType = if ($isDir) { "Folder" } else { "File" }

$confirm = [System.Windows.Forms.MessageBox]::Show(
    "FORCE DELETE ${itemType}:`n`n$itemName`n`nFull path: $resolved`n`nThis will kill locking processes and permanently delete it.",
    "Force Delete - Confirm",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning
)

if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
    exit 0
}

# ── Helper to check if target still exists ──
function TargetExists {
    return (Test-Path -LiteralPath $resolved)
}

# ── Step 1: Nuclear Ownership & ACL reset ──
function Reset-PermissionsAndAttributes {
    try {
        # Strip Read-only, System, Hidden attributes
        $null = cmd /c "attrib -r -s -h `"$resolved`" /s /d 2>nul"
    } catch {}

    try {
        $currentUser = $env:USERNAME
        if ($isDir) {
            $null = cmd /c "takeown /f `"$resolved`" /r /d y 2>nul"
            $null = cmd /c "takeown /a /f `"$resolved`" /r /d y 2>nul"
            $null = cmd /c "icacls `"$resolved`" /grant:r Everyone:(OI)(CI)F /t /c /q 2>nul"
            $null = cmd /c "icacls `"$resolved`" /grant:r Administrators:(OI)(CI)F /t /c /q 2>nul"
            $null = cmd /c "icacls `"$resolved`" /grant:r `"$currentUser`":(OI)(CI)F /t /c /q 2>nul"
        }
        else {
            $null = cmd /c "takeown /f `"$resolved`" /d y 2>nul"
            $null = cmd /c "takeown /a /f `"$resolved`" /d y 2>nul"
            $null = cmd /c "icacls `"$resolved`" /grant:r Everyone:F /c /q 2>nul"
            $null = cmd /c "icacls `"$resolved`" /grant:r Administrators:F /c /q 2>nul"
            $null = cmd /c "icacls `"$resolved`" /grant:r `"$currentUser`":F /c /q 2>nul"
        }
    } catch {}
}

Reset-PermissionsAndAttributes

# ── Step 2: Try immediate deletion before scanning ──
try {
    if ($isDir) {
        [System.IO.Directory]::Delete($resolved, $true)
    } else {
        [System.IO.File]::Delete($resolved)
    }
} catch {}

if (-not (TargetExists)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Successfully deleted:`n$resolved",
        "Force Delete - Success",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    exit 0
}

# ── Step 3: Find and Kill ALL Locking Processes ──
function Kill-LockingProcesses {
    # 1. Collect resources to check: MUST include the directory itself!
    $targetsToCheck = @($resolved)

    if ($isDir) {
        try {
            $children = Get-ChildItem -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty FullName -First 100
            if ($children) { $targetsToCheck += $children }
        } catch {}
    }

    # 2. Query Windows Restart Manager API
    $lockingPids = [System.Collections.Generic.HashSet[int]]::new()
    try {
        $pids = [FileUnlocker]::GetLockingProcessIds($targetsToCheck)
        foreach ($id in $pids) {
            if ($id -ne $PID -and $id -ne 0 -and $id -ne 4) {
                $lockingPids.Add($id) | Out-Null
            }
        }
    } catch {}

    # 3. Process Scan Fallback: find any process whose exe, module, or command line matches target
    try {
        $normTarget = $resolved.TrimEnd('\', '/').ToLower()
        $allProcs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.Id -ne 0 -and $_.Id -ne 4 }

        foreach ($p in $allProcs) {
            try {
                if ($p.Path -and $p.Path.ToLower().StartsWith($normTarget)) {
                    $lockingPids.Add($p.Id) | Out-Null
                    continue
                }
                foreach ($mod in $p.Modules) {
                    if ($mod.FileName -and $mod.FileName.ToLower().StartsWith($normTarget)) {
                        $lockingPids.Add($p.Id) | Out-Null
                        break
                    }
                }
            } catch {}
        }
    } catch {}

    # 4. Terminate all locking processes immediately
    $killedExplorer = $false
    foreach ($pidToKill in $lockingPids) {
        $proc = Get-Process -Id $pidToKill -ErrorAction SilentlyContinue
        if ($proc) {
            if ($proc.ProcessName -ieq "explorer") {
                $killedExplorer = $true
            }
            try {
                $proc | Stop-Process -Force -ErrorAction Stop
            }
            catch {
                $null = taskkill /F /PID $pidToKill /T 2>&1
                if (Get-Command gsudo -ErrorAction SilentlyContinue) {
                    $null = gsudo taskkill /F /PID $pidToKill /T 2>&1
                }
            }
        }
    }

    # 5. Brief sleep to allow Windows kernel handles to close
    Start-Sleep -Milliseconds 400

    # 6. If Explorer was killed to release a folder lock, restart it
    if ($killedExplorer) {
        Start-Process explorer.exe
        Start-Sleep -Milliseconds 600
    }
}

Kill-LockingProcesses

# ── Step 4: Multi-Engine Wipe ──

# Attempt A: .NET Delete
try {
    if ($isDir) {
        [System.IO.Directory]::Delete($resolved, $true)
    } else {
        [System.IO.File]::Delete($resolved)
    }
} catch {}

# Attempt B: Robocopy Empty Mirror Purge (Obliterates folder contents instantly)
if ((TargetExists) -and $isDir) {
    try {
        $emptyTemp = Join-Path $env:TEMP ("fd_empty_" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $emptyTemp -Force | Out-Null
        $null = robocopy "$emptyTemp" "$resolved" /MIR /R:1 /W:0 /NP /NFL /NDL /NJH /NJS 2>&1
        Remove-Item -LiteralPath $emptyTemp -Force -ErrorAction SilentlyContinue
        [System.IO.Directory]::Delete($resolved, $true)
    } catch {}
}

# Attempt C: Extended-length Path (\\?\) RD / DEL via CMD
if (TargetExists) {
    try {
        $ext = if ($resolved.StartsWith("\\?\")) { $resolved } else { "\\?\" + $resolved }
        if ($isDir) {
            $null = cmd /c "rd /s /q `"$ext`"" 2>&1
        } else {
            $null = cmd /c "del /f /q /a `"$ext`"" 2>&1
        }
    } catch {}
}

# Attempt D: PowerShell Remove-Item Force
if (TargetExists) {
    try {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
    } catch {}
}

# Attempt E: gsudo elevated wipe (if available)
if ((TargetExists) -and (Get-Command gsudo -ErrorAction SilentlyContinue)) {
    try {
        if ($isDir) {
            $null = gsudo cmd /c "takeown /f `"$resolved`" /r /d y && icacls `"$resolved`" /grant Everyone:(OI)(CI)F /t /c /q && rd /s /q `"$resolved`"" 2>&1
        } else {
            $null = gsudo cmd /c "takeown /f `"$resolved`" /d y && icacls `"$resolved`" /grant Everyone:F /c /q && del /f /q /a `"$resolved`"" 2>&1
        }
    } catch {}
}

# ── Final Status ──
if (-not (TargetExists)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Successfully deleted:`n$resolved",
        "Force Delete - Success",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    exit 0
}
else {
    # If a kernel driver still locks it, silently schedule reboot delete as safety net
    try {
        if ($isDir) {
            Get-ChildItem -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue |
                Sort-Object { $_.FullName.Length } -Descending |
                ForEach-Object {
                    [FileUnlocker]::MoveFileEx($_.FullName, $null, [FileUnlocker]::MOVEFILE_DELAY_UNTIL_REBOOT) | Out-Null
                }
        }
        [FileUnlocker]::MoveFileEx($resolved, $null, [FileUnlocker]::MOVEFILE_DELAY_UNTIL_REBOOT) | Out-Null
    } catch {}

    [System.Windows.Forms.MessageBox]::Show(
        "Could not delete immediately.`nThe item is locked by a Windows kernel driver or active system service.`n`nIt has been marked to delete automatically on next reboot:`n$resolved",
        "Force Delete - Locked by System",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
    exit 1
}
