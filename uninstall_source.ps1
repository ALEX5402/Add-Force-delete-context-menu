<#
.SYNOPSIS
    Force Delete - Standalone Uninstaller (single-file executable source).

.DESCRIPTION
    This is the source that build.ps1 compiles into Uninstall-ForceDelete.exe.
    It behaves exactly like Uninstall_Force-context-menu.bat -> uninstall.ps1,
    but it is fully self-contained: uninstall.reg and clean_old_entries.reg
    are embedded in this file (build.ps1 replaces the __*_B64__ placeholders
    with Base64 payloads), so no separate downloads are needed.

    1. Removes ALL Force Delete context menu entries (old + new versions),
       including the Windows Settings uninstall entry
    2. Imports the embedded uninstall.reg / clean_old_entries.reg files
    3. Optionally reverts the Windows 11 classic context menu setting
    4. Restarts Explorer to apply changes immediately
    5. Deletes the %ProgramFiles%\ForceDelete installation folder

    Must be run as Administrator (the compiled exe requests UAC via its manifest).
#>

# ── Require Administrator ──
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    Write-Host "Restarting as Administrator..." -ForegroundColor Yellow
    try {
        $currentExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $isCompiledExe = $currentExe -and $currentExe.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase) -and
            -not $currentExe.EndsWith("powershell.exe", [System.StringComparison]::OrdinalIgnoreCase) -and
            -not $currentExe.EndsWith("pwsh.exe", [System.StringComparison]::OrdinalIgnoreCase)
        if ($isCompiledExe) {
            Start-Process $currentExe -Verb RunAs
        }
        else {
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Definition)`"" -Verb RunAs
        }
        exit
    }
    catch {
        Write-Host ""
        Write-Host "ERROR: Administrator privileges are required to uninstall." -ForegroundColor Red
        Write-Host "Right-click 'Uninstall-ForceDelete.exe' and select 'Run as administrator'." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Press Enter to exit..."
        $null = Read-Host
        exit 1
    }
}

$ErrorActionPreference = "SilentlyContinue"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Force Delete - Context Menu Uninstaller" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ── Embedded payloads (filled in by build.ps1 — do not edit these values) ──
$uninstallRegB64    = "__UNINSTALL_REG_B64__"
$cleanOldEntriesB64 = "__CLEAN_OLD_ENTRIES_REG_B64__"

# ── Helper to remove registry keys cleanly via reg.exe (avoids PowerShell wildcard hang) ──
function Remove-RegistryKeySafely([string]$KeyPath) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        $null = & reg.exe query "$KeyPath" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $null = & reg.exe delete "$KeyPath" /f 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Removed: $KeyPath" -ForegroundColor Green
                return $true
            }
            else {
                Write-Host "  WARNING: Failed to delete: $KeyPath" -ForegroundColor Red
                return $false
            }
        }
        else {
            Write-Host "  Not found (OK): $KeyPath" -ForegroundColor DarkGray
            return $false
        }
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

# ── Helper to import a .reg text payload via reg.exe import ──
function Import-RegText([string]$RegText, [string]$Label) {
    $tempRegPath = Join-Path $env:TEMP ("fd_" + $Label + "_" + [Guid]::NewGuid().ToString("N") + ".reg")
    [System.IO.File]::WriteAllText($tempRegPath, $RegText, [System.Text.Encoding]::Unicode)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        $null = & reg.exe import "$tempRegPath"
    }
    finally {
        $ErrorActionPreference = $prev
    }
    Remove-Item -Path $tempRegPath -Force -ErrorAction SilentlyContinue
}

# ── Remove ALL known context menu entries ──
Write-Host "[1/3] Removing context menu entries..." -ForegroundColor Yellow

$keysToRemove = @(
    # New version keys (ForceDelete - no underscore)
    "HKLM\Software\Classes\*\shell\ForceDelete",
    "HKLM\Software\Classes\Directory\shell\ForceDelete",
    "HKCU\Software\Classes\*\shell\ForceDelete",
    "HKCU\Software\Classes\Directory\shell\ForceDelete",

    # Old version keys (Force_Delete - with underscore, from the original Python project)
    "HKLM\Software\Classes\*\shell\Force_Delete",
    "HKLM\Software\Classes\Directory\shell\Force_Delete",
    "HKCU\Software\Classes\*\shell\Force_Delete",
    "HKCU\Software\Classes\Directory\shell\Force_Delete",

    # Windows Settings > Installed Apps entry
    "HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\ForceDelete"
)

$removedCount = 0

foreach ($key in $keysToRemove) {
    if (Remove-RegistryKeySafely -KeyPath $key) {
        $removedCount++
    }
}

# Import the embedded .reg files as well (same content as uninstall.reg / clean_old_entries.reg)
$uninstallRegText = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($uninstallRegB64))
Import-RegText -RegText $uninstallRegText -Label "uninstall"
$cleanRegText = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($cleanOldEntriesB64))
Import-RegText -RegText $cleanRegText -Label "cleanold"
Write-Host "  Applied embedded uninstall.reg / clean_old_entries.reg" -ForegroundColor Green

if ($removedCount -eq 0) {
    Write-Host "  No context menu entries were found to remove." -ForegroundColor DarkGray
}

Write-Host ""

# ── Optionally revert Windows 11 classic context menu ──
Write-Host "[2/3] Windows 11 classic context menu check..." -ForegroundColor Yellow

$classicKeyPath = "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}"
$classicKeyExists = $false
$prev = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
$null = & reg.exe query "$classicKeyPath" 2>&1
if ($LASTEXITCODE -eq 0) {
    $classicKeyExists = $true
}
$ErrorActionPreference = $prev

if ($classicKeyExists) {
    Write-Host ""
    Write-Host "  --------------------------------------------------" -ForegroundColor Cyan
    Write-Host "  Windows 11 Classic Context Menu Override Detected" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------" -ForegroundColor Cyan
    Write-Host "  [1] Revert to default Windows 11 modern context menu" -ForegroundColor Green
    Write-Host "  [2] Keep classic context menu enabled" -ForegroundColor DarkCyan
    Write-Host ""
    $ans = Read-Host "  Select option [1 or 2] (Default is 1)"
    if ([string]::IsNullOrWhiteSpace($ans) -or $ans.Trim() -eq "1" -or $ans.Trim() -match '^(?i)y') {
        Remove-RegistryKeySafely -KeyPath $classicKeyPath | Out-Null
        Write-Host ""
        Write-Host "  Reverted to Windows 11 modern context menu." -ForegroundColor Green

        # Restart Explorer cleanly and non-blocking
        Write-Host "  Restarting Explorer..." -ForegroundColor Yellow
        & cmd.exe /c "taskkill /f /im explorer.exe >nul 2>&1 & start explorer.exe"
        Start-Sleep -Seconds 1
        Write-Host "  Explorer restarted." -ForegroundColor Green
    }
    else {
        Write-Host ""
        Write-Host "  Keeping classic context menu." -ForegroundColor DarkGray
    }
}
else {
    Write-Host "  Classic menu override not found. No changes needed." -ForegroundColor DarkGray
}

Write-Host ""

# ── Clean up Program Files installation folder if present ──
Write-Host "[3/3] Cleaning up installation folder..." -ForegroundColor Yellow

$installedProgramFolder = Join-Path $env:ProgramFiles "ForceDelete"
if (Test-Path $installedProgramFolder) {
    # If this uninstaller is running from inside the install folder, the running
    # exe file itself is locked by Windows — schedule it for deletion on reboot.
    $currentExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($currentExe -and $currentExe.StartsWith($installedProgramFolder, [System.StringComparison]::OrdinalIgnoreCase)) {
        try {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class RebootDelete {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
}
"@ -ErrorAction SilentlyContinue
            [RebootDelete]::MoveFileEx($currentExe, $null, 4) | Out-Null
        }
        catch {}
    }

    try {
        Remove-Item -Path $installedProgramFolder -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $installedProgramFolder)) {
            Write-Host "  Cleaned up application folder: $installedProgramFolder" -ForegroundColor Green
        }
        else {
            Write-Host "  Application folder will be fully removed on next reboot (files in use)." -ForegroundColor Yellow
        }
    }
    catch {}
}
else {
    Write-Host "  Application folder not found (OK): $installedProgramFolder" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "   Uninstallation Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "All Force Delete context menu entries have been removed." -ForegroundColor White
Write-Host ""
Write-Host "Press Enter to exit..." -ForegroundColor Cyan
$null = Read-Host
