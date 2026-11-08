<#
.SYNOPSIS
    Force Delete - Forcefully and INSTANTLY deletes any file or folder (single or multiple selection).

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
    [Parameter(Mandatory = $false, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Paths = @(),
    [Parameter(Mandatory = $false)]
    [string]$Path = ""
)

# Normalize single-path (legacy / %1) and multi-path (%*) invocations.
$rawInputPaths = @()
if ($Paths) { $rawInputPaths += $Paths }
if (-not [string]::IsNullOrWhiteSpace($Path)) { $rawInputPaths += $Path }
$quotedInputPaths = ($rawInputPaths | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '

# ── Load Windows Forms for dialogs ──
Add-Type -AssemblyName System.Windows.Forms

# ── Ensure running as Administrator ──
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    $currentExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $isCompiledExe = $currentExe -and $currentExe.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase) -and 
        -not $currentExe.EndsWith("powershell.exe", [System.StringComparison]::OrdinalIgnoreCase) -and 
        -not $currentExe.EndsWith("pwsh.exe", [System.StringComparison]::OrdinalIgnoreCase)

    try {
        if ($isCompiledExe) {
            Start-Process $currentExe -ArgumentList $quotedInputPaths -Verb RunAs
        }
        else {
            $scriptPath = if ($MyInvocation.MyCommand.Definition) { $MyInvocation.MyCommand.Definition } else { $PSCommandPath }
            $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
            if ($quotedInputPaths) { $argList += " $quotedInputPaths" }
            Start-Process powershell.exe -ArgumentList $argList -Verb RunAs
        }
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

# ── Validate and resolve paths (single file/folder OR multiple selection) ──
if ($rawInputPaths.Count -eq 0) {
    # No path supplied (e.g. user double-clicked the executable) - prompt to select a file or folder
    $targetChoice = [System.Windows.Forms.MessageBox]::Show(
        "Force Delete`n`nWould you like to select a File or a Folder to delete?`n`n• Click [Yes] to choose a FILE`n• Click [No] to choose a FOLDER`n• Click [Cancel] to exit",
        "Force Delete - Select Target",
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($targetChoice -eq [System.Windows.Forms.DialogResult]::Yes) {
        $fileDlg = New-Object System.Windows.Forms.OpenFileDialog
        $fileDlg.Title = "Select File to Force Delete"
        $fileDlg.Filter = "All Files (*.*)|*.*"
        $fileDlg.CheckFileExists = $true
        if ($fileDlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $rawInputPaths = @($fileDlg.FileName)
        }
        else {
            exit 0
        }
    }
    elseif ($targetChoice -eq [System.Windows.Forms.DialogResult]::No) {
        $folderDlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderDlg.Description = "Select Folder to Force Delete"
        $folderDlg.ShowNewFolderButton = $false
        if ($folderDlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $rawInputPaths = @($folderDlg.SelectedPath)
        }
        else {
            exit 0
        }
    }
    else {
        exit 0
    }
}

$resolvedPaths = @()
$missingPaths = @()
foreach ($inputPath in $rawInputPaths) {
    if ([string]::IsNullOrWhiteSpace($inputPath)) { continue }
    try {
        $candidatePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($inputPath)
    }
    catch {
        $missingPaths += $inputPath
        continue
    }
    if (Test-Path -LiteralPath $candidatePath) {
        if ($resolvedPaths -notcontains $candidatePath) {
            $resolvedPaths += $candidatePath
        }
    }
    else {
        $missingPaths += $candidatePath
    }
}

if ($missingPaths.Count -gt 0) {
    [System.Windows.Forms.MessageBox]::Show(
        "The following path(s) do not exist:`n" + ($missingPaths -join "`n"),
        "Force Delete - Not Found",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

if ($resolvedPaths.Count -eq 0) {
    exit 0
}

# ── Coalesce multi-select invocations into ONE popup ──
# Explorer may invoke this verb once per selected item instead of once with the
# whole selection. Each invocation drops its paths into a shared session file;
# the first invocation waits briefly for the others, then handles the ENTIRE
# selection with a single confirmation. Later invocations exit silently.
try {
    $sessionDir = Join-Path $env:TEMP 'ForceDeleteSession'
    $pathsFile = Join-Path $sessionDir 'paths.txt'
    $ownerFile = Join-Path $sessionDir 'owner.txt'
    New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

    $amOwner = $false
    try {
        $ownerStream = [System.IO.File]::Open($ownerFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $ownerStream.Close()
        $amOwner = $true
    }
    catch {
        # Owner file already exists — take over if it is stale (owner crashed)
        try {
            if (((Get-Date) - (Get-Item $ownerFile).LastWriteTime).TotalSeconds -gt 30) {
                Remove-Item $ownerFile -Force -ErrorAction SilentlyContinue
                $ownerStream = [System.IO.File]::Open($ownerFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $ownerStream.Close()
                $amOwner = $true
            }
        }
        catch {}
    }

    foreach ($p in $resolvedPaths) {
        Add-Content -Path $pathsFile -Value $p -Encoding UTF8 -ErrorAction SilentlyContinue
    }

    if (-not $amOwner) {
        # Another invocation is collecting the selection — stay silent.
        exit 0
    }

    # Wait until the paths file stops growing (sibling invocations appending)
    $lastSize = -1
    $waited = 0
    while ($waited -lt 3000) {
        Start-Sleep -Milliseconds 250
        $waited += 250
        $size = 0
        try { $size = (Get-Item $pathsFile -ErrorAction Stop).Length } catch {}
        if ($size -eq $lastSize) { break }
        $lastSize = $size
    }

    $sessionPaths = @()
    try {
        $sessionPaths = Get-Content -Path $pathsFile -ErrorAction Stop |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) }
    }
    catch {}

    if ($sessionPaths.Count -gt 0) {
        $resolvedPaths = @($resolvedPaths + $sessionPaths | Sort-Object -Unique)
    }

    Remove-Item -Path $sessionDir -Recurse -Force -ErrorAction SilentlyContinue
}
catch {}

# If a folder and one of its children were both selected, keep only the folder —
# deleting it already removes the child.
$sortedPaths = $resolvedPaths | Sort-Object Length
$resolvedPaths = @()
foreach ($candidatePath in $sortedPaths) {
    $isChildOfSelected = $false
    foreach ($keptPath in $resolvedPaths) {
        $keptTrimmed = $keptPath.TrimEnd('\', '/')
        if ($candidatePath.StartsWith($keptTrimmed + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $isChildOfSelected = $true
            break
        }
    }
    if (-not $isChildOfSelected) {
        $resolvedPaths += $candidatePath
    }
}

# ── Confirmation Dialog (single confirmation for the whole selection) ──
if ($resolvedPaths.Count -eq 1) {
    $resolved = $resolvedPaths[0]
    $itemName = Split-Path $resolved -Leaf
    $isDir = (Get-Item -LiteralPath $resolved -Force) -is [System.IO.DirectoryInfo]
    $itemType = if ($isDir) { "Folder" } else { "File" }
    $confirmText = "FORCE DELETE ${itemType}:`n`n$itemName`n`nFull path: $resolved`n`nThis will kill locking processes and permanently delete it."
}
else {
    $confirmLines = @()
    foreach ($selectedPath in ($resolvedPaths | Select-Object -First 20)) {
        $selectedName = Split-Path $selectedPath -Leaf
        $selectedType = if ((Get-Item -LiteralPath $selectedPath -Force) -is [System.IO.DirectoryInfo]) { "Folder" } else { "File" }
        $confirmLines += "- $selectedName ($selectedType)`n  $selectedPath"
    }
    if ($resolvedPaths.Count -gt 20) {
        $confirmLines += "... and $($resolvedPaths.Count - 20) more"
    }
    $confirmText = "FORCE DELETE $($resolvedPaths.Count) items:`n`n" + ($confirmLines -join "`n") + "`n`nThis will kill locking processes and permanently delete them."
}

$confirm = [System.Windows.Forms.MessageBox]::Show(
    $confirmText,
    "Force Delete - Confirm",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning
)

if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
    exit 0
}

$deletedPaths = @()
$lockedPaths = @()

foreach ($resolved in $resolvedPaths) {
    $isDir = (Get-Item -LiteralPath $resolved -Force) -is [System.IO.DirectoryInfo]

# ── Helper to check if target still exists ──
function TargetExists {
    return (Test-Path -LiteralPath $resolved)
}

# ── Helper: run an external tool with NO console window (no flashing) ──
function Invoke-HiddenProcess([string]$FileName, [string]$Arguments) {
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $FileName
        $psi.Arguments = $Arguments
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()
    } catch {}
}

# ── Step 1: Nuclear Ownership & ACL reset (all helper tools run hidden) ──
function Reset-PermissionsAndAttributes {
    $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    try {
        # Strip Read-only, System, Hidden attributes
        Invoke-HiddenProcess $cmdExe "/c attrib -r -s -h `"$resolved`" /s /d"
    } catch {}

    try {
        $currentUser = $env:USERNAME
        if ($isDir) {
            Invoke-HiddenProcess $cmdExe "/c takeown /f `"$resolved`" /r /d y"
            Invoke-HiddenProcess $cmdExe "/c takeown /a /f `"$resolved`" /r /d y"
            Invoke-HiddenProcess $cmdExe "/c icacls `"$resolved`" /grant:r Everyone:(OI)(CI)F /t /c /q"
            Invoke-HiddenProcess $cmdExe "/c icacls `"$resolved`" /grant:r Administrators:(OI)(CI)F /t /c /q"
            Invoke-HiddenProcess $cmdExe "/c icacls `"$resolved`" /grant:r `"$currentUser`":(OI)(CI)F /t /c /q"
        }
        else {
            Invoke-HiddenProcess $cmdExe "/c takeown /f `"$resolved`" /d y"
            Invoke-HiddenProcess $cmdExe "/c takeown /a /f `"$resolved`" /d y"
            Invoke-HiddenProcess $cmdExe "/c icacls `"$resolved`" /grant:r Everyone:F /c /q"
            Invoke-HiddenProcess $cmdExe "/c icacls `"$resolved`" /grant:r Administrators:F /c /q"
            Invoke-HiddenProcess $cmdExe "/c icacls `"$resolved`" /grant:r `"$currentUser`":F /c /q"
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
    $deletedPaths += $resolved
    continue
}

# ── Step 3: Multi-engine wipe WITHOUT killing anything first ──
# (killing Explorer flashes the whole screen black while it restarts,
#  so process-killing is only used when these attempts fail)
function Invoke-WipeAttempts {
    # Attempt A: .NET Delete
    try {
        if ($isDir) {
            [System.IO.Directory]::Delete($resolved, $true)
        } else {
            [System.IO.File]::Delete($resolved)
        }
    } catch {}

    # Attempt B: Robocopy Empty Mirror Purge (hidden — no console flash)
    if ((TargetExists) -and $isDir) {
        try {
            $emptyTemp = Join-Path $env:TEMP ("fd_empty_" + [Guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $emptyTemp -Force | Out-Null
            Invoke-HiddenProcess (Join-Path $env:SystemRoot 'System32\robocopy.exe') "`"$emptyTemp`" `"$resolved`" /MIR /R:1 /W:0 /NP /NFL /NDL /NJH /NJS"
            Remove-Item -LiteralPath $emptyTemp -Force -ErrorAction SilentlyContinue
            [System.IO.Directory]::Delete($resolved, $true)
        } catch {}
    }

    # Attempt C: Extended-length Path (\\?\) RD / DEL via CMD (hidden)
    if (TargetExists) {
        try {
            $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
            $ext = if ($resolved.StartsWith("\\?\")) { $resolved } else { "\\?\" + $resolved }
            if ($isDir) {
                Invoke-HiddenProcess $cmdExe "/c rd /s /q `"$ext`""
            } else {
                Invoke-HiddenProcess $cmdExe "/c del /f /q /a `"$ext`""
            }
        } catch {}
    }

    # Attempt D: PowerShell Remove-Item Force
    if (TargetExists) {
        try {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
        } catch {}
    }
}

Invoke-WipeAttempts

if (-not (TargetExists)) {
    $deletedPaths += $resolved
    continue
}

# ── Step 4: Find and Kill Locking Processes (Explorer excluded for now) ──
function Kill-LockingProcesses {
    param([bool]$IncludeExplorer = $false)
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

    # 4. Terminate locking processes. Explorer is skipped unless explicitly
    #    included — killing it restarts the whole shell and flashes the
    #    screen black, so it is only a last resort.
    $killedExplorer = $false
    $taskkillExe = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    foreach ($pidToKill in $lockingPids) {
        $proc = Get-Process -Id $pidToKill -ErrorAction SilentlyContinue
        if ($proc) {
            if ($proc.ProcessName -ieq "explorer") {
                if (-not $IncludeExplorer) { continue }
                $killedExplorer = $true
            }
            try {
                $proc | Stop-Process -Force -ErrorAction Stop
            }
            catch {
                Invoke-HiddenProcess $taskkillExe "/F /PID $pidToKill /T"
                if (Get-Command gsudo -ErrorAction SilentlyContinue) {
                    Invoke-HiddenProcess 'gsudo' "taskkill /F /PID $pidToKill /T"
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

Kill-LockingProcesses -IncludeExplorer $false

Invoke-WipeAttempts

if (-not (TargetExists)) {
    $deletedPaths += $resolved
    continue
}

# ── Step 5: Explorer as a LAST resort ──
# Only reached if the target is still locked after everything else. Killing
# Explorer restarts the shell (brief black flash), so this runs rarely.
Kill-LockingProcesses -IncludeExplorer $true

Invoke-WipeAttempts

if (-not (TargetExists)) {
    $deletedPaths += $resolved
    continue
}

# ── Step 6: gsudo elevated wipe (if available, hidden) ──
if ((TargetExists) -and (Get-Command gsudo -ErrorAction SilentlyContinue)) {
    try {
        if ($isDir) {
            Invoke-HiddenProcess 'gsudo' "cmd /c takeown /f `"$resolved`" /r /d y && icacls `"$resolved`" /grant Everyone:(OI)(CI)F /t /c /q && rd /s /q `"$resolved`""
        } else {
            Invoke-HiddenProcess 'gsudo' "cmd /c takeown /f `"$resolved`" /d y && icacls `"$resolved`" /grant Everyone:F /c /q && del /f /q /a `"$resolved`""
        }
    } catch {}
}

# ── Per-item status (continue with the rest of the selection) ──
if (-not (TargetExists)) {
    $deletedPaths += $resolved
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

    $lockedPaths += $resolved
}

} # end foreach ($resolved in $resolvedPaths)

# ── Final Status (one summary for the whole selection) ──
if ($lockedPaths.Count -eq 0) {
    if ($deletedPaths.Count -eq 1) {
        $summaryText = "Successfully deleted:`n$($deletedPaths[0])"
    }
    else {
        $summaryText = "Successfully deleted $($deletedPaths.Count) items:`n" + ($deletedPaths -join "`n")
    }
    [System.Windows.Forms.MessageBox]::Show(
        $summaryText,
        "Force Delete - Success",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    exit 0
}
else {
    $summaryText = ""
    if ($deletedPaths.Count -gt 0) {
        $summaryText += "Deleted $($deletedPaths.Count) item(s):`n" + ($deletedPaths -join "`n") + "`n`n"
    }
    $summaryText += "Could not delete immediately.`nThe following item(s) are locked by a Windows kernel driver or active system service.`n`nThey have been marked to delete automatically on next reboot:`n" + ($lockedPaths -join "`n")
    [System.Windows.Forms.MessageBox]::Show(
        $summaryText,
        "Force Delete - Locked by System",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
    exit 1
}
