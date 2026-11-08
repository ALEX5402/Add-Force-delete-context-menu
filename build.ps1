<#
.SYNOPSIS
    Build script for Force Delete.
    Generates EXACTLY 2 standalone Windows executables using PS2EXE:
      - ForceDelete-Setup.exe        (installer — behaves like Install_Add-Force-context-menu.bat -> install.ps1)
      - Uninstall-ForceDelete.exe    (uninstaller — behaves like Uninstall_Force-context-menu.bat -> uninstall.ps1)

    Both executables are fully self-contained single files:
      - The installer embeds force_delete.ps1, clean_old_entries.reg,
        uninstall.reg and Uninstall-ForceDelete.exe, and deploys them to
        %ProgramFiles%\ForceDelete at install time.
      - The uninstaller embeds uninstall.reg and clean_old_entries.reg.

    No other executables are generated. In particular there is NO
    ForceDelete-x64/x86/arm64.exe: those were the force_delete.ps1
    deleter compiled standalone (double-clicking one shows the deleter's
    file/folder picker GUI, not the installer). The context menu entry
    installed by the .bat scripts points at
    powershell.exe -File "force_delete.ps1" "%1" %*, so the installer
    registers exactly that — no compiled deleter binary is needed.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   Force Delete - Build Pipeline" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 1. Output directory
$dist = Join-Path $root "dist"
if (Test-Path $dist) {
    Write-Host "Cleaning dist folder..." -ForegroundColor DarkGray
    try {
        Remove-Item -Path $dist -Recurse -Force -ErrorAction Stop
    }
    catch {
        throw "Could not clean the dist folder. Close any running ForceDelete-Setup.exe / Uninstall-ForceDelete.exe window first, then run build.ps1 again. ($($_.Exception.Message))"
    }
}
New-Item -ItemType Directory -Path $dist | Out-Null
Write-Host "Created dist directory: $dist" -ForegroundColor Green
Write-Host ""

# 2. Check and install PS2EXE
Write-Host "Checking for PS2EXE module..." -ForegroundColor Yellow
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Installing PS2EXE from PSGallery..." -ForegroundColor Yellow
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe -Force
Write-Host "PS2EXE module loaded successfully." -ForegroundColor Green
Write-Host ""

function Get-Base64([string]$Path) {
    if (-not (Test-Path $Path)) {
        throw "Required payload file not found: $Path"
    }
    return [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path))
}

$uninstallRegPath    = Join-Path $root "uninstall.reg"
$cleanOldEntriesPath = Join-Path $root "clean_old_entries.reg"
$forceDeletePs1Path  = Join-Path $root "force_delete.ps1"
$setupSourcePath     = Join-Path $root "setup_source.ps1"
$uninstallSourcePath = Join-Path $root "uninstall_source.ps1"

$uninstallRegB64    = Get-Base64 $uninstallRegPath
$cleanOldEntriesB64 = Get-Base64 $cleanOldEntriesPath
$forceDeletePs1B64  = Get-Base64 $forceDeletePs1Path

# 3. [1/2] Build the standalone Uninstaller (first — the installer embeds it)
$uninstallerExePath = Join-Path $dist "Uninstall-ForceDelete.exe"
$bundledUninstallPs1 = Join-Path $dist ".bundled_uninstall.ps1"

Write-Host "[1/2] Building Uninstall-ForceDelete.exe (self-contained uninstaller)..." -ForegroundColor Cyan

$uninstallTemplate = [System.IO.File]::ReadAllText($uninstallSourcePath)
if ($uninstallTemplate -notmatch "__UNINSTALL_REG_B64__") {
    throw "uninstall_source.ps1 is missing the __UNINSTALL_REG_B64__ placeholder."
}
$bundledUninstallCode = $uninstallTemplate.
    Replace("__UNINSTALL_REG_B64__", $uninstallRegB64).
    Replace("__CLEAN_OLD_ENTRIES_REG_B64__", $cleanOldEntriesB64)
[System.IO.File]::WriteAllText($bundledUninstallPs1, $bundledUninstallCode, [System.Text.Encoding]::UTF8)

# NOTE: no -noConsole here — the uninstaller is a console app (prompts + pause),
# exactly like Uninstall_Force-context-menu.bat -> uninstall.ps1.
Invoke-ps2exe `
    -InputFile $bundledUninstallPs1 `
    -OutputFile $uninstallerExePath `
    -requireAdmin `
    -title "Force Delete Uninstaller" `
    -description "Uninstalls Force Delete context menu entries" `
    -company "alex5402" `
    -product "Force Delete" `
    -version "1.0.0.0" `
    -copyright "alex5402"

if (-not (Test-Path $uninstallerExePath)) {
    throw "Failed to build $uninstallerExePath"
}
Write-Host "  Built: $uninstallerExePath" -ForegroundColor Green
Write-Host ""

# 4. [2/2] Build the standalone Installer (embeds everything, including the uninstaller)
$setupExePath = Join-Path $dist "ForceDelete-Setup.exe"
$bundledSetupPs1 = Join-Path $dist ".bundled_setup.ps1"

Write-Host "[2/2] Building ForceDelete-Setup.exe (self-contained installer)..." -ForegroundColor Cyan

$uninstallerExeB64 = Get-Base64 $uninstallerExePath

$setupTemplate = [System.IO.File]::ReadAllText($setupSourcePath)
foreach ($token in @("__FORCE_DELETE_PS1_B64__", "__UNINSTALL_REG_B64__", "__CLEAN_OLD_ENTRIES_REG_B64__", "__UNINSTALLER_EXE_B64__")) {
    if ($setupTemplate -notmatch [regex]::Escape($token)) {
        throw "setup_source.ps1 is missing the $token placeholder."
    }
}
$bundledSetupCode = $setupTemplate.
    Replace("__FORCE_DELETE_PS1_B64__", $forceDeletePs1B64).
    Replace("__UNINSTALL_REG_B64__", $uninstallRegB64).
    Replace("__CLEAN_OLD_ENTRIES_REG_B64__", $cleanOldEntriesB64).
    Replace("__UNINSTALLER_EXE_B64__", $uninstallerExeB64)
[System.IO.File]::WriteAllText($bundledSetupPs1, $bundledSetupCode, [System.Text.Encoding]::UTF8)

# NOTE: no -noConsole here — the installer is a console app (prompts + pause),
# exactly like Install_Add-Force-context-menu.bat -> install.ps1.
Invoke-ps2exe `
    -InputFile $bundledSetupPs1 `
    -OutputFile $setupExePath `
    -requireAdmin `
    -title "Force Delete Setup" `
    -description "All-in-One Installer for Force Delete Context Menu" `
    -company "alex5402" `
    -product "Force Delete" `
    -version "1.0.0.0" `
    -copyright "alex5402"

if (-not (Test-Path $setupExePath)) {
    throw "Failed to build $setupExePath"
}
Write-Host "  Built: $setupExePath" -ForegroundColor Green

# 5. Clean up build intermediates and verify the output is exactly the 2 release executables
Remove-Item -Path $bundledSetupPs1, $bundledUninstallPs1 -Force -ErrorAction SilentlyContinue

$expectedExes = @('ForceDelete-Setup.exe', 'Uninstall-ForceDelete.exe') | Sort-Object
$builtExes = Get-ChildItem -Path $dist -Filter *.exe | Select-Object -ExpandProperty Name | Sort-Object
if (Compare-Object $builtExes $expectedExes) {
    throw "Release output must contain exactly: $($expectedExes -join ', '). Found: $($builtExes -join ', ')"
}

$bannedArtifacts = Get-ChildItem -Path $dist -Include '*x64*', '*x86*', '*arm64*', '*.zip' -Recurse -ErrorAction SilentlyContinue
if ($bannedArtifacts) {
    throw "Banned release artifact(s) found: $($bannedArtifacts.Name -join ', ')"
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "   Build Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Get-ChildItem -Path $dist | Select-Object Name, Length | Format-Table -AutoSize
