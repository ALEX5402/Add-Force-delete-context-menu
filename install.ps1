<#
.SYNOPSIS
    Install "Force Delete" into the Windows right-click context menu.

.DESCRIPTION
    This script:
    1. REMOVES any old "Force_Delete" context menu entries from the previous version
    2. Installs a clean "Force Delete" context menu entry for files AND folders
    3. Works on Windows 10 and Windows 11 (appears in classic / "Show more options" menu)
    4. Optionally enables the classic context menu on Windows 11 so the entry appears
       directly on right-click without needing "Show more options"

    Must be run as Administrator.
#>

# ── Require Administrator ──
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    Write-Host "Restarting as Administrator..." -ForegroundColor Yellow
    try {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Definition)`"" -Verb RunAs
        exit
    }
    catch {
        Write-Host ""
        Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
        Write-Host "Right-click 'Install_Add-Force-context-menu.bat' and select 'Run as administrator'," -ForegroundColor Yellow
        Write-Host "or open PowerShell as Admin and run: .\install.ps1" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 1
    }
}

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   Force Delete - Context Menu Installer" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

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

# ── Step 1: Remove OLD entries (from the previous broken version) ──
Write-Host "[1/4] Removing old context menu entries..." -ForegroundColor Yellow

$oldKeys = @(
    "HKLM\Software\Classes\*\shell\Force_Delete",
    "HKLM\Software\Classes\Directory\shell\Force_Delete",
    "HKCU\Software\Classes\*\shell\Force_Delete",
    "HKCU\Software\Classes\Directory\shell\Force_Delete"
)

foreach ($key in $oldKeys) {
    Remove-RegistryKeySafely -KeyPath $key | Out-Null
}

Write-Host ""

# ── Step 2: Determine script path ──
Write-Host "[2/4] Setting up Force Delete script..." -ForegroundColor Yellow

if (-not $forceDeleteScriptOverride) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    if ([string]::IsNullOrWhiteSpace($scriptDir)) {
        $scriptDir = $PSScriptRoot
    }
    $forceDeleteScript = Join-Path $scriptDir "force_delete.ps1"
}
else {
    $forceDeleteScript = $forceDeleteScriptOverride
}

if (-not (Test-Path $forceDeleteScript)) {
    Write-Host "  ERROR: Could not find force_delete.ps1 in: $forceDeleteScript" -ForegroundColor Red
    Write-Host "  Press Enter to exit..." -ForegroundColor Yellow
    $null = Read-Host
    exit 1
}

Write-Host "  Script: $forceDeleteScript" -ForegroundColor Green
Write-Host ""

# ── Step 3: Create new context menu entries ──
Write-Host "[3/4] Adding new context menu entries..." -ForegroundColor Yellow

$escapedScript = $forceDeleteScript.Replace('\', '\\')
$q = [char]34
$slashQ = '\' + $q

# The command to invoke from the context menu (with properly quoted paths for files with spaces):
# powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\path\force_delete.ps1" "%1"
$regCommandLine = '@=' + $q + 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ' + $slashQ + $escapedScript + $slashQ + ' ' + $slashQ + '%1' + $slashQ + $q

# Windows Settings > Installed Apps entry, pointing at the .bat uninstaller (same folder)
$uninstallScript = Join-Path $scriptDir "uninstall.ps1"
$escapedUninstallScript = $uninstallScript.Replace('\', '\\')
$uninstallCommandLine = '@=' + $q + 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ' + $slashQ + $escapedUninstallScript + $slashQ + $q
$escapedScriptDir = $scriptDir.Replace('\', '\\')

$regLines = @(
    'Windows Registry Editor Version 5.00',
    '',
    '[HKEY_LOCAL_MACHINE\Software\Classes\*\shell\ForceDelete]',
    ('@=' + $q + 'Force Delete' + $q),
    ($q + 'HasLUAShield' + $q + '=' + $q + $q),
    ($q + 'NoWorkingDirectory' + $q + '=' + $q + $q),
    ($q + 'NeverDefault' + $q + '=' + $q + $q),
    ($q + 'Position' + $q + '=' + $q + 'bottom' + $q),
    '',
    '[HKEY_LOCAL_MACHINE\Software\Classes\*\shell\ForceDelete\command]',
    $regCommandLine,
    '',
    '[HKEY_LOCAL_MACHINE\Software\Classes\Directory\shell\ForceDelete]',
    ('@=' + $q + 'Force Delete' + $q),
    ($q + 'HasLUAShield' + $q + '=' + $q + $q),
    ($q + 'NoWorkingDirectory' + $q + '=' + $q + $q),
    ($q + 'Position' + $q + '=' + $q + 'bottom' + $q),
    '',
    '[HKEY_LOCAL_MACHINE\Software\Classes\Directory\shell\ForceDelete\command]',
    $regCommandLine,
    '',
    '[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall\ForceDelete]',
    ('@=' + $q + 'Force Delete Context Menu' + $q),
    ($q + 'DisplayName' + $q + '=' + $q + 'Force Delete Context Menu' + $q),
    ($q + 'DisplayVersion' + $q + '=' + $q + '1.0.0' + $q),
    ($q + 'Publisher' + $q + '=' + $q + 'alex5402' + $q),
    ($q + 'DisplayIcon' + $q + '=' + $q + 'imageres.dll,-78' + $q),
    ($q + 'UninstallString' + $q + '=' + $uninstallCommandLine),
    ($q + 'InstallLocation' + $q + '=' + $q + $escapedScriptDir + $q),
    ($q + 'NoModify' + $q + '=dword:00000001'),
    ($q + 'NoRepair' + $q + '=dword:00000001')
)

$tempRegPath = Join-Path $env:TEMP ("fd_install_" + [Guid]::NewGuid().ToString("N") + ".reg")
[System.IO.File]::WriteAllLines($tempRegPath, $regLines, [System.Text.Encoding]::Unicode)

# Import into registry cleanly via reg.exe import (without 2>&1 to prevent NativeCommandError when $ErrorActionPreference = "Stop")
$prev = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
try {
    $null = & reg.exe import "$tempRegPath"
}
finally {
    $ErrorActionPreference = $prev
}
Remove-Item -Path $tempRegPath -Force -ErrorAction SilentlyContinue

Write-Host "  Added: File & Folder context menu entries" -ForegroundColor Green
Write-Host ""

# ── Step 4: Windows 11 Context Menu Style (Classic vs Modern) ──
Write-Host "[4/4] Windows 11 context menu configuration..." -ForegroundColor Yellow

$osVersion = [System.Environment]::OSVersion.Version
$isWin11 = $osVersion.Build -ge 22000

if ($isWin11) {
    $classicKeyPath = "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
    $isCurrentlyClassic = $false

    $prev = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $null = & reg.exe query "$classicKeyPath" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $isCurrentlyClassic = $true
    }
    $ErrorActionPreference = $prev

    $currentStatusText = if ($isCurrentlyClassic) { "Classic (Windows 10 style, all options visible directly)" } else { "Modern (Windows 11 default, 'Show more options' collapsed)" }

    Write-Host ""
    Write-Host "  --------------------------------------------------" -ForegroundColor Cyan
    Write-Host "  Windows 11 Context Menu Style Choice:" -ForegroundColor Cyan
    Write-Host "  Current style: $currentStatusText" -ForegroundColor White
    Write-Host ""
    Write-Host "  [1] Classic Menu - 'Force Delete' appears directly on right-click" -ForegroundColor Green
    Write-Host "  [2] Modern Menu  - Default Windows 11 look ('Show more options')" -ForegroundColor DarkCyan
    Write-Host "  --------------------------------------------------" -ForegroundColor Cyan
    Write-Host ""

    $choice = "1"
    $raw = Read-Host "  Select option [1 or 2] (Default is 1)"
    if ($raw -and $raw.Trim() -eq "2") {
        $choice = "2"
    }

    if ($choice -eq "1") {
        Write-Host ""
        Write-Host "  Applying Windows 11 classic context menu..." -ForegroundColor Cyan

        # Create temporary .reg file to cleanly set (Default) = "" without cmdline escaping or overwrite prompts
        $tempClassicReg = Join-Path $env:TEMP ("fd_classic_" + [Guid]::NewGuid().ToString("N") + ".reg")
        $q = [char]34
        $classicLines = @(
            "Windows Registry Editor Version 5.00",
            "",
            "[HKEY_CURRENT_USER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32]",
            ('@=' + $q + $q)
        )
        [System.IO.File]::WriteAllLines($tempClassicReg, $classicLines, [System.Text.Encoding]::Unicode)

        $prev = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        try {
            $null = & reg.exe import "$tempClassicReg"
        }
        finally {
            $ErrorActionPreference = $prev
        }
        Remove-Item -Path $tempClassicReg -Force -ErrorAction SilentlyContinue

        Write-Host "  Classic context menu enabled! ('Force Delete' visible directly on right-click)" -ForegroundColor Green

        Write-Host "  Restarting Explorer to apply changes..." -ForegroundColor Yellow
        & cmd.exe /c "taskkill /f /im explorer.exe >nul 2>&1 & start explorer.exe"
        Start-Sleep -Seconds 1
        Write-Host "  Explorer restarted." -ForegroundColor Green
    }
    else {
        if ($isCurrentlyClassic) {
            Remove-RegistryKeySafely -KeyPath "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}" | Out-Null
            Write-Host ""
            Write-Host "  Reverted to Windows 11 modern context menu." -ForegroundColor Green
            Write-Host "  Restarting Explorer to apply changes..." -ForegroundColor Yellow
            & cmd.exe /c "taskkill /f /im explorer.exe >nul 2>&1 & start explorer.exe"
            Start-Sleep -Seconds 1
            Write-Host "  Explorer restarted." -ForegroundColor Green
        }
        else {
            Write-Host ""
            Write-Host "  Keeping Windows 11 modern menu ('Force Delete' under 'Show more options')." -ForegroundColor Cyan
        }
    }
}
else {
    Write-Host "  Windows 10 or earlier detected. Full context menu is always available natively." -ForegroundColor Green
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "   Installation Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "You can now right-click any file or folder and select 'Force Delete'." -ForegroundColor White
Write-Host ""
Write-Host "IMPORTANT: Do NOT move or delete force_delete.ps1 from:" -ForegroundColor Yellow
Write-Host "  $forceDeleteScript" -ForegroundColor Yellow
Write-Host ""
Write-Host "Press Enter to exit..." -ForegroundColor Cyan
$null = Read-Host

