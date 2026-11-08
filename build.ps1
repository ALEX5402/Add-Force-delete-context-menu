<#
.SYNOPSIS
    Build script for Force Delete.
    Compiles PowerShell scripts into standalone Windows executables using PS2EXE:
      - ForceDelete-x64.exe (64-bit standalone)
      - ForceDelete-x86.exe (32-bit standalone)
      - ForceDelete-arm64.exe (ARM64 / AnyCPU standalone)
      - Install-ForceDelete.exe (Single executable installer)
      - Uninstall-ForceDelete.exe (Single executable uninstaller)
      - ForceDelete-Source-Scripts.zip (Source / script package)
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

# 3. Build standalone ForceDelete executables
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

# 4. Build single executable Installer
Write-Host "[4/5] Building Install-ForceDelete.exe..." -ForegroundColor Cyan
# Generate a self-contained installer script that embeds force_delete.ps1 and installs to Program Files
$forceDeleteContent = Get-Content $forceDeletePs1 -Raw
$forceDeleteB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($forceDeleteContent))

$standaloneInstallerScript = Join-Path $dist "installer_standalone.ps1"
$installerBaseCode = Get-Content $installPs1 -Raw

$installerStandaloneCode = @"
# Force Delete - Self-Contained Standalone Installer
`$ErrorActionPreference = "Stop"

`$targetDir = Join-Path `$env:ProgramFiles "ForceDelete"
if (-not (Test-Path `$targetDir)) {
    New-Item -ItemType Directory -Path `$targetDir -Force | Out-Null
}

# Extract embedded force_delete.ps1 to Program Files
`$b64 = "$forceDeleteB64"
`$decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$b64))
`$permanentScriptPath = Join-Path `$targetDir "force_delete.ps1"
[System.IO.File]::WriteAllText(`$permanentScriptPath, `$decoded, [System.Text.Encoding]::UTF8)

# Run installer logic pointing to permanent script location
`$forceDeleteScriptOverride = `$permanentScriptPath
"@ + "`r`n" + $installerBaseCode

[System.IO.File]::WriteAllText($standaloneInstallerScript, $installerStandaloneCode, [System.Text.Encoding]::UTF8)

Invoke-ps2exe `
    -InputFile $standaloneInstallerScript `
    -OutputFile (Join-Path $dist "Install-ForceDelete.exe") `
    -requireAdmin `
    -title "Force Delete Installer" `
    -description "Installs Force Delete into Windows right-click context menu" `
    -company "alex5402" `
    -product "Force Delete" `
    -version "1.0.0.0" `
    -copyright "alex5402"

Remove-Item -Path $standaloneInstallerScript -Force -ErrorAction SilentlyContinue

# 5. Build single executable Uninstaller
Write-Host "[5/5] Building Uninstall-ForceDelete.exe..." -ForegroundColor Cyan
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

# 6. Create portable source zip
Write-Host "Creating ForceDelete-Source-Scripts.zip..." -ForegroundColor Cyan
$zipFiles = @(
    "Install_Add-Force-context-menu.bat",
    "Uninstall_Force-context-menu.bat",
    "install.ps1",
    "uninstall.ps1",
    "force_delete.ps1",
    "clean_old_entries.reg",
    "uninstall.reg",
    "README.md",
    "LICENSE"
) | ForEach-Object { Join-Path $root $_ } | Where-Object { Test-Path $_ }

$zipPath = Join-Path $dist "ForceDelete-Source-Scripts.zip"
Compress-Archive -Path $zipFiles -DestinationPath $zipPath -Force

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "   Build Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Get-ChildItem -Path $dist | Select-Object Name, Length | Format-Table -AutoSize

