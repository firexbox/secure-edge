# Secure Edge Launcher for Windows
# Version 2.7 - Three-mode storage: full encryption / encrypted root + local cache / local root + encrypted privacy

param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Arguments = @()
)

# Win32 API for creating symlinks (target does NOT need to exist)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Symlink {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool CreateSymbolicLink(string lpSymlinkFileName, string lpTargetFileName, int dwFlags);
}
"@

# Auto-elevate to admin (required for file symlinks)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @(
        "-ExecutionPolicy", "Bypass",
        "-NoProfile",
        "-File", "`"$($MyInvocation.MyCommand.Path)`""
    ) + $Arguments
    Start-Process PowerShell -Verb RunAs -ArgumentList $argList
    exit
}

$EncryptionAvailable = $false
$EncryptionStatus = $null

if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$EncryptionModule = Join-Path $PSScriptRoot "encryption.psm1"

if (Test-Path $EncryptionModule) {
    Write-Host "Loading encryption module..." -ForegroundColor Yellow
    try {
        Remove-Module encryption -Force -ErrorAction SilentlyContinue
        Import-Module $EncryptionModule -Force -DisableNameChecking -ErrorAction Stop
        $EncryptionStatus = Get-EncryptionStatus -ErrorAction Stop
        $EncryptionAvailable = $true
        Write-Host "Encryption functions verified OK" -ForegroundColor Green
    } catch {
        Write-Host "Encryption module failed to load: $_" -ForegroundColor Red
        $EncryptionAvailable = $false
    }
}

$ScriptDir = $PSScriptRoot
$ConfigDir = Join-Path $ScriptDir "config_edge"
$PasswordFile = Join-Path $ConfigDir "password_edge.enc"
$ContainerPath = Join-Path $ScriptDir "UserData.hc"
$ModeFile = Join-Path $ConfigDir "mode.cfg"

# Local data directory (always on launch disk)
$LocalDataDir = Join-Path $ScriptDir "EdgeUserData"

# Edge user data root — defaults to local; overridden based on mode
$script:DataDir = $LocalDataDir
$script:EncryptedDir = $null
$Mode = $null  # 1=full encryption, 2=encrypted root+local cache, 3=local root+encrypted privacy

# Mode 3 — Privacy-sensitive files (file symlinks to encrypted drive, dwFlags=0)
$SensitiveFiles = @(
    "Default\Login Data",
    "Default\Login Data-journal",
    "Default\History",
    "Default\History-journal",
    "Default\Bookmarks",
    "Default\Bookmarks.bak",
    "Default\Cookies",
    "Default\Cookies-journal",
    "Default\Favicons",
    "Default\Favicons-journal",
    "Default\Web Data",
    "Default\Web Data-journal",
    "Default\Shortcuts",
    "Default\Shortcuts-journal",
    "Default\Top Sites",
    "Default\Top Sites-journal",
    "Default\Preferences",
    "Default\Secure Preferences",
    "Default\Visited Links",
    "Local State",
    "Default\Network\TransportSecurity",
    "Default\Network\Cookies",
    "Default\Network\Cookies-journal",
    "Default\Network\Trust Tokens",
    "Default\Network\Trust Tokens-journal",
    "Default\Network\Reporting and NEL",
    "Default\Network\Reporting and NEL-journal",
    "Default\Network\Network Persistent State",
    "Default\Network\Device Bound Sessions",
    "Default\Network\Device Bound Sessions-journal",
    "Default\Network Action Predictor",
    "Default\DIPS",
    "Default\DIPS-journal",
    "Default\Site Characteristics Database-journal",
    "Default\Safe Browsing Network",
    "Default\Safe Browsing Network-journal",
    "Default\Affiliation Database",
    "Default\Affiliation Database-journal",
    "Default\heavy_ad_intervention_opt_out.db",
    "Default\heavy_ad_intervention_opt_out.db-journal"
)

# Mode 3 — Privacy-sensitive directories (directory symlinks to encrypted drive, dwFlags=1)
$SensitiveDirs = @(
    "Default\Sessions",
    "Default\Sync Data",
    "Default\Local Storage",
    "Default\Storage",
    "Default\WebStorage",
    "Default\Shared Dictionary",
    "Default\Service Worker",
    "Default\Site Characteristics Database"
)

# Cache directories symlinked from encrypted drive to local disk (dwFlags=1)
# These can grow >100MB and are non-private/disposable
$LocalCacheDirs = @(
    "Default\Cache",
    "Default\Code Cache",
    "Default\AutofillAiModelCache",
    "Default\optimization_guide_hint_cache_store",
    "Default\DawnGraphiteCache",
    "Default\DawnWebGPUCache",
    "Default\GPUCache",
    "GPUPersistentCache",
    "extensions_crx_cache",
    "component_crx_cache"
)

function Get-SavedMode {
    if (Test-Path $ModeFile) {
        $content = (Get-Content $ModeFile -Raw).Trim()
        if ($content -match '^[123]$') { return [int]$content }
    }
    return $null
}

function Set-Mode {
    param([Parameter(Mandatory=$true)][int]$Mode)
    if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
    $Mode | Out-File $ModeFile -NoNewline
}

function Select-Mode {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Secure Edge — Storage Mode Setup" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] Full Encryption" -ForegroundColor White
    Write-Host "      All Edge data stored on encrypted drive." -ForegroundColor Gray
    Write-Host "      Safest option — needs enough encrypted volume space." -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [2] Encrypted Root + Local Cache  (recommended)" -ForegroundColor White
    Write-Host "      Core data on encrypted drive, large caches on local disk." -ForegroundColor Gray
    Write-Host "      Good balance of security and space efficiency." -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [3] Local Root + Encrypted Privacy" -ForegroundColor White
    Write-Host "      Data on local disk, only privacy-sensitive files encrypted." -ForegroundColor Gray
    Write-Host "      Best performance, minimal encrypted volume usage." -ForegroundColor Gray
    Write-Host ""

    do {
        $choice = Read-Host "Select mode [1/2/3]"
    } while ($choice -notmatch '^[123]$')

    $mode = [int]$choice
    Set-Mode -Mode $mode
    Write-Host "Mode $mode saved to config_edge\mode.cfg" -ForegroundColor Green
    return $mode
}

function Find-Edge {
    $paths = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe",
        "msedge.exe"
    )
    foreach ($path in $paths) {
        if ($path -eq "msedge.exe") {
            $exe = (Get-Command $path -ErrorAction SilentlyContinue).Source
            if ($exe) { return $exe }
        } elseif (Test-Path $path) {
            return $path
        }
    }
    return $null
}

$UseEncryption = $false
if ($EncryptionAvailable -and $EncryptionStatus) {
    if ($EncryptionStatus.ContainerExists -and $EncryptionStatus.VeraCryptInstalled) {
        $UseEncryption = $true
    }
}

function New-SensitiveSymlinks {
    param()
    if (-not $script:EncryptedDir) { return $true }

    Write-Host "Linking sensitive data to encrypted drive..." -ForegroundColor Cyan

    foreach ($file in $SensitiveFiles) {
        $linkPath = Join-Path $script:DataDir $file
        $targetPath = Join-Path $script:EncryptedDir $file

        $linkParent = Split-Path $linkPath -Parent
        $targetParent = Split-Path $targetPath -Parent
        if (-not (Test-Path $linkParent)) { New-Item -ItemType Directory -Path $linkParent -Force | Out-Null }
        if (-not (Test-Path $targetParent)) { New-Item -ItemType Directory -Path $targetParent -Force | Out-Null }

        $existing = Get-Item $linkPath -Force -ErrorAction SilentlyContinue
        $attr = 0
        if ($existing) { $attr = [int]$existing.Attributes }
        $isReparse = ($attr -band 0x400) -ne 0

        if ($existing -and -not $isReparse) {
            Write-Host "  Migrating: $file" -ForegroundColor Gray
            Copy-Item $linkPath $targetPath -Force -ErrorAction SilentlyContinue
        }

        Remove-Item $linkPath -Recurse -Force -ErrorAction SilentlyContinue

        if ([Symlink]::CreateSymbolicLink($linkPath, $targetPath, 0)) {
            Write-Host "  $file" -ForegroundColor Gray
        } else {
            Write-Host "  FAILED: $file" -ForegroundColor Red
            return $false
        }
    }

    foreach ($dir in $SensitiveDirs) {
        $linkPath = Join-Path $script:DataDir $dir
        $targetPath = Join-Path $script:EncryptedDir $dir

        $linkParent = Split-Path $linkPath -Parent
        $targetParent = Split-Path $targetPath -Parent
        if (-not (Test-Path $linkParent)) { New-Item -ItemType Directory -Path $linkParent -Force | Out-Null }
        if (-not (Test-Path $targetParent)) { New-Item -ItemType Directory -Path $targetParent -Force | Out-Null }

        $existing = Get-Item $linkPath -Force -ErrorAction SilentlyContinue
        $attr = 0
        if ($existing) { $attr = [int]$existing.Attributes }
        $isReparse = ($attr -band 0x400) -ne 0

        if ($existing -and -not $isReparse) {
            Write-Host "  Migrating dir: $dir" -ForegroundColor Gray
            New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
            Start-Process -FilePath "robocopy.exe" -ArgumentList @(
                "`"$linkPath`"", "`"$targetPath`"",
                "/E", "/MOVE", "/R:0", "/W:0",
                "/NFL", "/NDL", "/NJH", "/NJS"
            ) -Wait -NoNewWindow
            Remove-Item $linkPath -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Remove-Item $linkPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        if (-not (Test-Path $targetPath)) {
            New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
        }

        if ([Symlink]::CreateSymbolicLink($linkPath, $targetPath, 1)) {
            Write-Host "  $dir\" -ForegroundColor Gray
        } else {
            Write-Host "  FAILED: $dir" -ForegroundColor Red
            return $false
        }
    }

    Write-Host "Sensitive data symlinks ready." -ForegroundColor Green
    return $true
}

function New-LocalCacheSymlinks {
    param()

    Write-Host "Linking cache directories to local disk..." -ForegroundColor Cyan

    foreach ($dir in $LocalCacheDirs) {
        $linkPath = Join-Path $script:DataDir $dir
        $targetPath = Join-Path $LocalDataDir $dir

        $linkParent = Split-Path $linkPath -Parent
        $targetParent = Split-Path $targetPath -Parent
        if (-not (Test-Path $linkParent)) {
            New-Item -ItemType Directory -Path $linkParent -Force | Out-Null
        }
        if (-not (Test-Path $targetParent)) {
            New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
        }

        $existing = Get-Item $linkPath -Force -ErrorAction SilentlyContinue
        $attr = 0
        if ($existing) { $attr = [int]$existing.Attributes }
        $isReparse = ($attr -band 0x400) -ne 0

        if ($isReparse) {
            Remove-Item $linkPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        elseif ($existing -and -not $isReparse) {
            Write-Host "  Moving cache to local: $dir" -ForegroundColor Gray
            if (-not (Test-Path $targetPath)) {
                New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
            }
            Start-Process -FilePath "robocopy.exe" -ArgumentList @(
                "`"$linkPath`"", "`"$targetPath`"",
                "/E", "/MOVE", "/R:0", "/W:0",
                "/NFL", "/NDL", "/NJH", "/NJS"
            ) -Wait -NoNewWindow
            Remove-Item $linkPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        if (-not (Test-Path $targetPath)) {
            New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
        }

        if ([Symlink]::CreateSymbolicLink($linkPath, $targetPath, 1)) {
            Write-Host "  $dir  ->  local" -ForegroundColor Gray
        } else {
            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Write-Host "  FAILED: $dir (Win32 error $err)" -ForegroundColor Red
            return $false
        }
    }

    Write-Host "Cache directories linked to local disk." -ForegroundColor Green
    return $true
}

function Mount-EncryptedDataDir {
    param([Parameter(Mandatory=$true)][System.Security.SecureString]$Password)
    $mountedPath = Mount-Container -ContainerPath $ContainerPath -Password $Password -DriveLetter "Y"
    if (-not $mountedPath) { return $false }

    Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    $EncryptedDataDir = Join-Path $mountedPath "EdgeUserData"
    $EncryptedPrivacyDir = Join-Path $mountedPath "SecureProfile"

    Write-Host "Mode $Mode : " -NoNewline
    switch ($Mode) {
        1 { Write-Host "Full encryption" -ForegroundColor Cyan }
        2 { Write-Host "Encrypted root + local cache" -ForegroundColor Cyan }
        3 { Write-Host "Local root + encrypted privacy" -ForegroundColor Cyan }
    }

    # === Shared: migrate old version data ===
    $oldProfile = Join-Path $mountedPath "SecureProfile"
    $oldEdge = Join-Path $mountedPath "SecureEdge"

    if (Test-Path $oldProfile) {
        Write-Host "Migrating old SecureProfile data..." -ForegroundColor Yellow
        if (-not (Test-Path $EncryptedDataDir)) {
            New-Item -ItemType Directory -Path $EncryptedDataDir -Force | Out-Null
        }
        Start-Process -FilePath "robocopy.exe" -ArgumentList @(
            "`"$oldProfile`"", "`"$EncryptedDataDir`"",
            "/E", "/MOVE", "/R:0", "/W:0",
            "/NFL", "/NDL", "/NJH", "/NJS"
        ) -Wait -NoNewWindow
        Remove-Item $oldProfile -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $oldEdge) {
        Write-Host "Migrating old SecureEdge data..." -ForegroundColor Yellow
        if (-not (Test-Path $EncryptedDataDir)) {
            New-Item -ItemType Directory -Path $EncryptedDataDir -Force | Out-Null
        }
        Start-Process -FilePath "robocopy.exe" -ArgumentList @(
            "`"$oldEdge`"", "`"$EncryptedDataDir`"",
            "/E", "/MOVE", "/R:0", "/W:0",
            "/NFL", "/NDL", "/NJH", "/NJS"
        ) -Wait -NoNewWindow
        Remove-Item $oldEdge -Recurse -Force -ErrorAction SilentlyContinue
    }

    # === Mode-specific setup ===
    switch ($Mode) {
        1 {
            # Full encryption: everything on Y:\EdgeUserData
            if (-not (Test-Path $EncryptedDataDir)) {
                New-Item -ItemType Directory -Path $EncryptedDataDir -Force | Out-Null
            }

            $existing = Get-Item $LocalDataDir -Force -ErrorAction SilentlyContinue
            if ($existing -and -not (($existing.Attributes -band 0x400) -ne 0)) {
                Write-Host "Migrating local data to encrypted drive..." -ForegroundColor Cyan
                Start-Process -FilePath "robocopy.exe" -ArgumentList @(
                    "`"$LocalDataDir`"", "`"$EncryptedDataDir`"",
                    "/E", "/MOVE", "/R:0", "/W:0",
                    "/NFL", "/NDL", "/NJH", "/NJS"
                ) -Wait -NoNewWindow
            }
            $script:DataDir = $EncryptedDataDir
        }

        2 {
            # Encrypted root + local cache: data on Y:, cache symlinks to local
            if (-not (Test-Path $EncryptedDataDir)) {
                New-Item -ItemType Directory -Path $EncryptedDataDir -Force | Out-Null
            }

            $existing = Get-Item $LocalDataDir -Force -ErrorAction SilentlyContinue
            $isReparse = $false
            if ($existing) { $isReparse = ($existing.Attributes -band 0x400) -ne 0 }

            if ($isReparse) {
                Write-Host "Removing old symlink..." -ForegroundColor Yellow
                Remove-Item $LocalDataDir -Recurse -Force
            }
            elseif ($existing) {
                Write-Host "Migrating local data to encrypted drive..." -ForegroundColor Cyan
                Start-Process -FilePath "robocopy.exe" -ArgumentList @(
                    "`"$LocalDataDir`"", "`"$EncryptedDataDir`"",
                    "/E", "/MOVE", "/R:0", "/W:0",
                    "/NFL", "/NDL", "/NJH", "/NJS"
                ) -Wait -NoNewWindow
                Get-ChildItem $LocalDataDir -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { ($_.Attributes -band 0x400) -ne 0 } |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                Get-ChildItem $LocalDataDir -Recurse -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { (Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0 } |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }

            if (-not (Test-Path $LocalDataDir)) {
                New-Item -ItemType Directory -Path $LocalDataDir -Force | Out-Null
            }

            $script:DataDir = $EncryptedDataDir

            if (-not (New-LocalCacheSymlinks)) {
                Write-Host "Cache symlink creation failed." -ForegroundColor Red
                Dismount-Container -DriveLetter "Y" -Force
                return $false
            }
        }

        3 {
            # Local root + encrypted privacy: data locally, sensitive files symlinked to Y:
            if (-not (Test-Path $EncryptedPrivacyDir)) {
                New-Item -ItemType Directory -Path $EncryptedPrivacyDir -Force | Out-Null
            }

            $existing = Get-Item $LocalDataDir -Force -ErrorAction SilentlyContinue
            if ($existing -and ($existing.Attributes -band 0x400)) {
                Write-Host "Removing old junction..." -ForegroundColor Yellow
                Remove-Item $LocalDataDir -Recurse -Force
            }
            if (-not (Test-Path $LocalDataDir)) {
                New-Item -ItemType Directory -Path $LocalDataDir -Force | Out-Null
            }

            $script:EncryptedDir = $EncryptedPrivacyDir
            $script:DataDir = $LocalDataDir

            if (-not (New-SensitiveSymlinks)) {
                Write-Host "Sensitive symlink creation failed." -ForegroundColor Red
                Dismount-Container -DriveLetter "Y" -Force
                return $false
            }
        }
    }

    return $true
}

function Dismount-EncryptedDataDir {
    if ($EncryptionAvailable -and (Test-ContainerMounted -DriveLetter "Y")) {
        Write-Host "Dismounting..." -ForegroundColor Yellow
        $retries = 0
        while ($retries -lt 5) {
            if (Dismount-Container -DriveLetter "Y") { return $true }
            Start-Sleep -Seconds 3
            $retries++
        }
        return $false
    }
    return $true
}

$BrowserArgs = @()
$doSetupPassword = $false
$doSetupEncryption = $false
$doSetupMode = $false

foreach ($arg in $Arguments) {
    if ($arg -match "setup-password") { $doSetupPassword = $true }
    elseif ($arg -match "setup-encryption") { $doSetupEncryption = $true }
    elseif ($arg -match "setup-mode") { $doSetupMode = $true }
    elseif ($arg -notmatch "^--(setup-encryption|setup-password|setup-mode|help)$" -and $arg -ne "--%") {
        $BrowserArgs += $arg
    }
}

if ($doSetupPassword) {
    & "$ScriptDir\setup-password-edge.ps1"
    exit $LASTEXITCODE
}

if ($doSetupEncryption) {
    if ($EncryptionAvailable) { Initialize-Encryption }
    else { Write-Host "Encryption module not available." -ForegroundColor Red }
    exit $LASTEXITCODE
}

# Mode selection
$Mode = Get-SavedMode
if ($doSetupMode -or -not $Mode) {
    if (-not $Mode) {
        Write-Host "No storage mode configured. Running first-time setup..." -ForegroundColor Yellow
    }
    $Mode = Select-Mode
    if ($doSetupMode) { exit 0 }
}

$EdgeExe = Find-Edge
if (-not $EdgeExe) {
    Write-Host "ERROR: Microsoft Edge not found." -ForegroundColor Red
    exit 1
}

if (Test-Path $PasswordFile) {
    $password = Read-Host "Enter Edge secure password" -AsSecureString
    if (-not $password) { exit 1 }

    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

    $storedHash = (Get-Content $PasswordFile -Raw).Trim()
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $inputHash = [System.BitConverter]::ToString($hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($plainPassword))).Replace("-", "").ToLower()
    $plainPassword = $null

    if ($inputHash -ne $storedHash) {
        Write-Host "Incorrect password." -ForegroundColor Red
        exit 1
    }

    if ($UseEncryption) {
        if (-not (Mount-EncryptedDataDir -Password $password)) { exit 1 }
    }
} else {
    Write-Host "No password set. Run 'se.bat --setup-password' first." -ForegroundColor Yellow
    exit 0
}

try {
    Add-Type -Name Window -Namespace Console -MemberDefinition '
        [DllImport("Kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("User32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    ' -ErrorAction Stop
    $hwnd = [Console.Window]::GetConsoleWindow()
    [Console.Window]::ShowWindow($hwnd, 6) | Out-Null
} catch {}

$allArgs = @(
    "--user-data-dir=`"$script:DataDir`"",
    "--no-first-run",
    "--disk-cache-size=104857600",
    "--media-cache-size=52428800"
) + $BrowserArgs
Write-Host "Launching Secure Edge..." -ForegroundColor Green
Start-Process -FilePath $EdgeExe -ArgumentList $allArgs | Out-Null

if ($UseEncryption) {
    Write-Host "Secure Edge is running. Close all Secure Edge windows to lock the encrypted drive." -ForegroundColor Cyan
    do {
        Start-Sleep -Seconds 3
        $ourProcesses = Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" |
            Where-Object { $_.CommandLine -like "*--user-data-dir=`"$script:DataDir`"*" }
    } while ($ourProcesses)
    Write-Host "Secure Edge closed." -ForegroundColor Green
    Start-Sleep -Seconds 5
    Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Dismount-Container -DriveLetter "Y" -Force
}
