<#
.SYNOPSIS
    Uninstall "Force Delete" from the Windows right-click context menu.

.DESCRIPTION
    This script:
    1. Removes ALL Force Delete context menu entries (both old and new versions)
    2. Optionally reverts the Windows 11 classic context menu setting
    3. Restarts Explorer to apply changes immediately

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
        Write-Host "Right-click 'Uninstall_Force-context-menu.bat' and select 'Run as administrator'," -ForegroundColor Yellow
        Write-Host "or open PowerShell as Admin and run: .\uninstall.ps1" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 1
    }
}

$ErrorActionPreference = "SilentlyContinue"
Add-Type -AssemblyName System.Windows.Forms

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Force Delete - Context Menu Uninstaller" -ForegroundColor Cyan
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

# ── Remove ALL known context menu entries ──
Write-Host "[1/2] Removing context menu entries..." -ForegroundColor Yellow

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
    "HKCU\Software\Classes\Directory\shell\Force_Delete"
)

$removedCount = 0

foreach ($key in $keysToRemove) {
    if (Remove-RegistryKeySafely -KeyPath $key) {
        $removedCount++
    }
}

if ($removedCount -eq 0) {
    Write-Host "  No context menu entries were found to remove." -ForegroundColor DarkGray
}

Write-Host ""

# ── Optionally revert Windows 11 classic context menu ──
Write-Host "[2/2] Windows 11 classic context menu check..." -ForegroundColor Yellow

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

# ── Clean up Program Files installation folder if present ──
$installedProgramFolder = Join-Path $env:ProgramFiles "ForceDelete"
if (Test-Path $installedProgramFolder) {
    try {
        Remove-Item -Path $installedProgramFolder -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  Cleaned up application folder: $installedProgramFolder" -ForegroundColor Green
    }
    catch {}
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

