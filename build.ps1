<#
.SYNOPSIS
    Build script for Force Delete.
    Compiles PowerShell scripts into standalone Windows executables using PS2EXE:
      - ForceDelete-Setup.exe (ALL-IN-ONE single executable installer containing all binaries and tools)
      - ForceDelete-Package.zip (Complete bundle of all executables and scripts)
      - ForceDelete-x64.exe (64-bit standalone binary)
      - ForceDelete-x86.exe (32-bit standalone binary)
      - ForceDelete-arm64.exe (ARM64 standalone binary)
      - Uninstall-ForceDelete.exe (Single executable uninstaller)
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
    Remove-Item -Path $dist -Recurse -Force
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

$forceDeletePs1 = Join-Path $root "force_delete.ps1"
$installPs1 = Join-Path $root "install.ps1"
$uninstallPs1 = Join-Path $root "uninstall.ps1"

# 3. Build standalone ForceDelete architecture executables
Write-Host "[1/5] Building ForceDelete-x64.exe..." -ForegroundColor Cyan
Invoke-ps2exe `
    -InputFile $forceDeletePs1 `
    -OutputFile (Join-Path $dist "ForceDelete-x64.exe") `
    -x64 `
    -noConsole `
    -requireAdmin `
    -title "Force Delete" `
    -description "Forcefully and instantly deletes locked files and folders" `
    -company "alex5402" `
    -product "Force Delete" `
    -version "1.0.0.0" `
    -copyright "alex5402"

Write-Host "[2/5] Building ForceDelete-x86.exe..." -ForegroundColor Cyan
Invoke-ps2exe `
    -InputFile $forceDeletePs1 `
    -OutputFile (Join-Path $dist "ForceDelete-x86.exe") `
    -x86 `
    -noConsole `
    -requireAdmin `
    -title "Force Delete (x86)" `
    -description "Forcefully and instantly deletes locked files and folders" `
    -company "alex5402" `
    -product "Force Delete" `
    -version "1.0.0.0" `
    -copyright "alex5402"

Write-Host "[3/5] Building ForceDelete-arm64.exe..." -ForegroundColor Cyan
Invoke-ps2exe `
    -InputFile $forceDeletePs1 `
    -OutputFile (Join-Path $dist "ForceDelete-arm64.exe") `
    -noConsole `
    -requireAdmin `
    -title "Force Delete (ARM64)" `
    -description "Forcefully and instantly deletes locked files and folders" `
    -company "alex5402" `
    -product "Force Delete" `
    -version "1.0.0.0" `
    -copyright "alex5402"

# 4. Build single executable Uninstaller
Write-Host "[4/5] Building Uninstall-ForceDelete.exe..." -ForegroundColor Cyan
Invoke-ps2exe `
    -InputFile $uninstallPs1 `
    -OutputFile (Join-Path $dist "Uninstall-ForceDelete.exe") `
    -requireAdmin `
    -title "Force Delete Uninstaller" `
    -description "Uninstalls Force Delete context menu entries" `
    -company "alex5402" `
    -product "Force Delete" `
    -version "1.0.0.0" `
    -copyright "alex5402"

# 5. Pack ALL executables, scripts, and registry files into a master package
Write-Host "[5/5] Packaging all executables into single ForceDelete-Setup.exe..." -ForegroundColor Cyan

$stagingDir = Join-Path $dist "staging_payload"
if (Test-Path $stagingDir) { Remove-Item -Path $stagingDir -Recurse -Force }
New-Item -ItemType Directory -Path $stagingDir | Out-Null

Copy-Item (Join-Path $dist "ForceDelete-x64.exe") $stagingDir
Copy-Item (Join-Path $dist "ForceDelete-x86.exe") $stagingDir
Copy-Item (Join-Path $dist "ForceDelete-arm64.exe") $stagingDir
Copy-Item (Join-Path $dist "Uninstall-ForceDelete.exe") $stagingDir
Copy-Item $forceDeletePs1 $stagingDir
Copy-Item $installPs1 $stagingDir
Copy-Item $uninstallPs1 $stagingDir
Copy-Item (Join-Path $root "Install_Add-Force-context-menu.bat") $stagingDir
Copy-Item (Join-Path $root "Uninstall_Force-context-menu.bat") $stagingDir
Copy-Item (Join-Path $root "clean_old_entries.reg") $stagingDir
Copy-Item (Join-Path $root "uninstall.reg") $stagingDir
Copy-Item (Join-Path $root "README.md") $stagingDir
Copy-Item (Join-Path $root "LICENSE") $stagingDir

$packageZip = Join-Path $dist "ForceDelete-Package.zip"
if (Test-Path $packageZip) { Remove-Item -Path $packageZip -Force }
Compress-Archive -Path "$stagingDir\*" -DestinationPath $packageZip -Force
Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue

# Embed the entire package into a single master installer script
$zipBytes = [System.IO.File]::ReadAllBytes($packageZip)
$zipB64 = [Convert]::ToBase64String($zipBytes)

$setupTemplate = @'
<#
.SYNOPSIS
    Force Delete - All-in-One Standalone Setup & Installer
    Self-contained single executable containing all architecture binaries, scripts, and tools.
#>
param(
    [switch]$Extract,
    [string]$ExtractPath = ""
)

$ErrorActionPreference = "Stop"

# Require Administrator unless running in extract mode
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin -and -not $Extract) {
    try {
        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        Start-Process $exePath -Verb RunAs
        exit
    }
    catch {
        Write-Host "ERROR: Administrator privileges required to install." -ForegroundColor Red
        Write-Host "Press Enter to exit..."
        $null = Read-Host
        exit 1
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   Force Delete - Context Menu Installer" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Unpack embedded payload
Add-Type -AssemblyName System.IO.Compression.FileSystem

$b64 = "PAYLOAD_BASE64_PLACEHOLDER"
$zipBytes = [Convert]::FromBase64String($b64)
$tempZip = Join-Path $env:TEMP ("fd_setup_" + [Guid]::NewGuid().ToString("N") + ".zip")
[System.IO.File]::WriteAllBytes($tempZip, $zipBytes)

function Extract-ZipSafely([string]$ZipPath, [string]$DestinationDir) {
    if (-not (Test-Path $DestinationDir)) {
        New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    }
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            $destPath = Join-Path $DestinationDir $entry.FullName
            $parentDir = Split-Path $destPath -Parent
            if (-not (Test-Path $parentDir)) {
                New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
            }
            if ($entry.Length -gt 0 -or -not $entry.FullName.EndsWith("/")) {
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destPath, $true)
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

# If user specified -Extract / /extract
if ($Extract) {
    $outDir = if ($ExtractPath) { $ExtractPath } else { Join-Path (Get-Location) "ForceDelete" }
    Write-Host "Extracting all executables and tools to: $outDir..." -ForegroundColor Yellow
    Extract-ZipSafely -ZipPath $tempZip -DestinationDir $outDir
    Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
    Write-Host "Extraction complete!" -ForegroundColor Green
    exit 0
}

# ── Installation Mode ──
$installDir = Join-Path $env:ProgramFiles "ForceDelete"
Write-Host "[1/4] Unpacking files to: $installDir..." -ForegroundColor Yellow
Extract-ZipSafely -ZipPath $tempZip -DestinationDir $installDir
Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue

# Detect architecture and select optimal native binary
$arch = $env:PROCESSOR_ARCHITECTURE
$isArm64 = ($arch -eq "ARM64") -or ($env:PROCESSOR_ARCHITEW6432 -eq "ARM64")
$is64Bit = [Environment]::Is64BitOperatingSystem

if ($isArm64) {
    $srcExe = Join-Path $installDir "ForceDelete-arm64.exe"
    Write-Host "  Architecture: ARM64 (Windows on ARM)" -ForegroundColor Cyan
}
elseif ($is64Bit) {
    $srcExe = Join-Path $installDir "ForceDelete-x64.exe"
    Write-Host "  Architecture: x64 (64-bit)" -ForegroundColor Cyan
}
else {
    $srcExe = Join-Path $installDir "ForceDelete-x86.exe"
    Write-Host "  Architecture: x86 (32-bit)" -ForegroundColor Cyan
}

$targetExe = Join-Path $installDir "ForceDelete.exe"
if (Test-Path $srcExe) {
    Copy-Item -Path $srcExe -Destination $targetExe -Force
}

# ── Step 2: Remove old broken context menu keys ──
Write-Host "[2/4] Removing old context menu entries..." -ForegroundColor Yellow
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
foreach ($k in $oldKeys) {
    $null = & reg.exe delete "$k" /f 2>&1
}

# ── Step 3: Register context menu entries with UAC shield ──
Write-Host "[3/4] Adding context menu entries with security shield icon..." -ForegroundColor Yellow

$q = [char]34
$slashQ = '\' + $q
if (Test-Path $targetExe) {
    $escapedExe = $targetExe.Replace('\', '\\')
    $cmdLine = '@=' + $q + $slashQ + $escapedExe + $slashQ + ' ' + $slashQ + '%1' + $slashQ + $q
}
else {
    $fallbackScript = (Join-Path $installDir "force_delete.ps1").Replace('\', '\\')
    $cmdLine = '@=' + $q + 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ' + $slashQ + $fallbackScript + $slashQ + ' ' + $slashQ + '%1' + $slashQ + $q
}

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
    $cmdLine,
    '',
    '[HKEY_LOCAL_MACHINE\Software\Classes\Directory\shell\ForceDelete]',
    ('@=' + $q + 'Force Delete' + $q),
    ($q + 'HasLUAShield' + $q + '=' + $q + $q),
    ($q + 'NoWorkingDirectory' + $q + '=' + $q + $q),
    ($q + 'Position' + $q + '=' + $q + 'bottom' + $q),
    '',
    '[HKEY_LOCAL_MACHINE\Software\Classes\Directory\shell\ForceDelete\command]',
    $cmdLine,
    '',
    '[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall\ForceDelete]',
    ('@=' + $q + 'Force Delete Context Menu' + $q),
    ($q + 'DisplayName' + $q + '=' + $q + 'Force Delete Context Menu' + $q),
    ($q + 'DisplayVersion' + $q + '=' + $q + '1.0.0' + $q),
    ($q + 'Publisher' + $q + '=' + $q + 'alex5402' + $q),
    ($q + 'DisplayIcon' + $q + '=' + $q + 'imageres.dll,-78' + $q),
    ($q + 'UninstallString' + $q + '=' + $q + $slashQ + (Join-Path $installDir "Uninstall-ForceDelete.exe").Replace('\', '\\') + $slashQ + $q),
    ($q + 'InstallLocation' + $q + '=' + $q + $installDir.Replace('\', '\\') + $q)
)

$tempReg = Join-Path $env:TEMP ("fd_reg_" + [Guid]::NewGuid().ToString("N") + ".reg")
[System.IO.File]::WriteAllLines($tempReg, $regLines, [System.Text.Encoding]::Unicode)
$null = & reg.exe import "$tempReg"
Remove-Item -Path $tempReg -Force -ErrorAction SilentlyContinue

Write-Host "  Added: File & Folder context menu entries" -ForegroundColor Green
Write-Host ""

# ── Step 4: Windows 11 Context Menu Style Choice ──
Write-Host "[4/4] Windows 11 context menu configuration..." -ForegroundColor Yellow
$osVersion = [System.Environment]::OSVersion.Version
$isWin11 = $osVersion.Build -ge 22000

if ($isWin11) {
    $classicKeyPath = "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
    $isCurrentlyClassic = $false
    $null = & reg.exe query "$classicKeyPath" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $isCurrentlyClassic = $true
    }

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
        $tempClassicReg = Join-Path $env:TEMP ("fd_classic_" + [Guid]::NewGuid().ToString("N") + ".reg")
        $classicLines = @(
            "Windows Registry Editor Version 5.00",
            "",
            "[HKEY_CURRENT_USER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32]",
            ('@=' + $q + $q)
        )
        [System.IO.File]::WriteAllLines($tempClassicReg, $classicLines, [System.Text.Encoding]::Unicode)
        $null = & reg.exe import "$tempClassicReg"
        Remove-Item -Path $tempClassicReg -Force -ErrorAction SilentlyContinue

        Write-Host "  Classic context menu enabled! ('Force Delete' visible directly on right-click)" -ForegroundColor Green
        Write-Host "  Restarting Explorer to apply changes..." -ForegroundColor Yellow
        & cmd.exe /c "taskkill /f /im explorer.exe >nul 2>&1 & start explorer.exe"
        Start-Sleep -Seconds 1
        Write-Host "  Explorer restarted." -ForegroundColor Green
    }
    else {
        if ($isCurrentlyClassic) {
            $null = & reg.exe delete "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}" /f 2>&1
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
Write-Host "Press Enter to exit..." -ForegroundColor Cyan
$null = Read-Host
'@

$bundledScriptPath = Join-Path $dist "setup_bundled.ps1"
$finalSetupCode = $setupTemplate.Replace("PAYLOAD_BASE64_PLACEHOLDER", $zipB64)
[System.IO.File]::WriteAllText($bundledScriptPath, $finalSetupCode, [System.Text.Encoding]::UTF8)

Invoke-ps2exe `
    -InputFile $bundledScriptPath `
    -OutputFile (Join-Path $dist "ForceDelete-Setup.exe") `
    -requireAdmin `
    -title "Force Delete Setup" `
    -description "All-in-One Installer for Force Delete Context Menu" `
    -company "alex5402" `
    -product "Force Delete" `
    -version "1.0.0.0" `
    -copyright "alex5402"

Remove-Item -Path $bundledScriptPath -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "   Build Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Get-ChildItem -Path $dist | Select-Object Name, Length | Format-Table -AutoSize
