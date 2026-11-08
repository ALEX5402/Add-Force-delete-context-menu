<#
.SYNOPSIS
    Force Delete - All-in-One Standalone Installer (single-file executable source).

.DESCRIPTION
    This is the source that build.ps1 compiles into ForceDelete-Setup.exe.
    It behaves exactly like Install_Add-Force-context-menu.bat -> install.ps1,
    but it is fully self-contained: force_delete.ps1, clean_old_entries.reg,
    uninstall.reg and Uninstall-ForceDelete.exe are embedded in this file
    (build.ps1 replaces the __*_B64__ placeholders with Base64 payloads),
    so no separate downloads are needed.

    1. REMOVES any old context menu entries (Force_Delete and ForceDelete)
    2. Deploys force_delete.ps1 (+ registry files + uninstaller) to
       %ProgramFiles%\ForceDelete
    3. Installs a clean "Force Delete" context menu entry for files AND folders
       pointing at: powershell.exe ... -File "...\force_delete.ps1" "%1"
       (identical to what install.ps1 registers)
    4. Optionally enables the classic context menu on Windows 11

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
        Write-Host "ERROR: Administrator privileges are required to install." -ForegroundColor Red
        Write-Host "Right-click 'ForceDelete-Setup.exe' and select 'Run as administrator'." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Press Enter to exit..."
        $null = Read-Host
        exit 1
    }
}

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   Force Delete - Context Menu Installer" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ── Embedded payloads (filled in by build.ps1 — do not edit these values) ──
$forceDeletePs1B64   = "__FORCE_DELETE_PS1_B64__"
$uninstallRegB64     = "__UNINSTALL_REG_B64__"
$cleanOldEntriesB64  = "__CLEAN_OLD_ENTRIES_REG_B64__"
$uninstallerExeB64   = "__UNINSTALLER_EXE_B64__"

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

# ── Step 1: Remove OLD entries (previous versions) ──
Write-Host "[1/4] Removing old context menu entries..." -ForegroundColor Yellow

$oldKeys = @(
    "HKLM\Software\Classes\*\shell\Force_Delete",
    "HKLM\Software\Classes\Directory\shell\Force_Delete",
    "HKCU\Software\Classes\*\shell\Force_Delete",
    "HKCU\Software\Classes\Directory\shell\Force_Delete",
    "HKLM\Software\Classes\*\shell\ForceDelete",
    "HKLM\Software\Classes\Directory\shell\ForceDelete",
    "HKCU\Software\Classes\*\shell\ForceDelete",
    "HKCU\Software\Classes\Directory\shell\ForceDelete"
)

foreach ($key in $oldKeys) {
    Remove-RegistryKeySafely -KeyPath $key | Out-Null
}

Write-Host ""

# ── Step 2: Deploy the embedded payload to %ProgramFiles%\ForceDelete ──
Write-Host "[2/4] Installing Force Delete files..." -ForegroundColor Yellow

$installDir = Join-Path $env:ProgramFiles "ForceDelete"
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

$forceDeleteScript = Join-Path $installDir "force_delete.ps1"
[System.IO.File]::WriteAllBytes($forceDeleteScript, [Convert]::FromBase64String($forceDeletePs1B64))

$uninstallRegPath = Join-Path $installDir "uninstall.reg"
[System.IO.File]::WriteAllText($uninstallRegPath, [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($uninstallRegB64)), [System.Text.Encoding]::Unicode)

$cleanRegPath = Join-Path $installDir "clean_old_entries.reg"
[System.IO.File]::WriteAllText($cleanRegPath, [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($cleanOldEntriesB64)), [System.Text.Encoding]::Unicode)

$uninstallerExePath = Join-Path $installDir "Uninstall-ForceDelete.exe"
[System.IO.File]::WriteAllBytes($uninstallerExePath, [Convert]::FromBase64String($uninstallerExeB64))

Write-Host "  Installed: $forceDeleteScript" -ForegroundColor Green
Write-Host "  Installed: $uninstallerExePath" -ForegroundColor Green
Write-Host ""

# ── Step 3: Create new context menu entries (identical to install.ps1) ──
Write-Host "[3/4] Adding new context menu entries..." -ForegroundColor Yellow

$escapedScript = $forceDeleteScript.Replace('\', '\\')
$q = [char]34
$slashQ = '\' + $q

# powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\...\force_delete.ps1" "%1"
$regCommandLine = '@=' + $q + 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ' + $slashQ + $escapedScript + $slashQ + ' ' + $slashQ + '%1' + $slashQ + $q

$escapedUninstaller = $uninstallerExePath.Replace('\', '\\')
$escapedInstallDir = $installDir.Replace('\', '\\')
$uninstallString = '@=' + $q + $slashQ + $escapedUninstaller + $slashQ + $q

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
    ($q + 'UninstallString' + $q + '=' + $q + $slashQ + $escapedUninstaller + $slashQ + $q),
    ($q + 'InstallLocation' + $q + '=' + $q + $escapedInstallDir + $q),
    ($q + 'NoModify' + $q + '=dword:00000001'),
    ($q + 'NoRepair' + $q + '=dword:00000001')
)

Import-RegText -RegText ([string]::Join("`r`n", $regLines)) -Label "install"

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

        $classicLines = @(
            "Windows Registry Editor Version 5.00",
            "",
            "[HKEY_CURRENT_USER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32]",
            ('@=' + $q + $q)
        )
        Import-RegText -RegText ([string]::Join("`r`n", $classicLines)) -Label "classic"

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
Write-Host "Force Delete has been installed to:" -ForegroundColor White
Write-Host "  $installDir" -ForegroundColor Cyan
Write-Host ""
Write-Host "You can now right-click any file or folder and select 'Force Delete'." -ForegroundColor White
Write-Host ""
Write-Host "To uninstall, run:" -ForegroundColor White
Write-Host "  $uninstallerExePath" -ForegroundColor Cyan
Write-Host "or uninstall from Windows Settings > Installed Apps." -ForegroundColor White
Write-Host ""
Write-Host "Press Enter to exit..." -ForegroundColor Cyan
$null = Read-Host
