# Secure Edge Launcher for Windows
# Version 2.6 - Encrypted root + local cache offloading

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

# Local data directory (always on launch disk, stores only disposable cache)
$LocalDataDir = Join-Path $ScriptDir "EdgeUserData"

# Edge user data root — defaults to local; overridden to Y:\EdgeUserData when encrypted
$script:DataDir = $LocalDataDir

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
    if (-not (Test-Path $EncryptedDataDir)) {
        New-Item -ItemType Directory -Path $EncryptedDataDir -Force | Out-Null
    }

    # Migrate old v2.5 SecureProfile data
    $oldProfile = Join-Path $mountedPath "SecureProfile"
    if (Test-Path $oldProfile) {
        Write-Host "Migrating v2.5 data..." -ForegroundColor Yellow
        Start-Process -FilePath "robocopy.exe" -ArgumentList @(
            "`"$oldProfile`"", "`"$EncryptedDataDir`"",
            "/E", "/MOVE", "/R:0", "/W:0",
            "/NFL", "/NDL", "/NJH", "/NJS"
        ) -Wait -NoNewWindow
        Remove-Item $oldProfile -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Migrate old v2.2 SecureEdge data
    $oldEdge = Join-Path $mountedPath "SecureEdge"
    if (Test-Path $oldEdge) {
        Write-Host "Migrating v2.2 data..." -ForegroundColor Yellow
        Start-Process -FilePath "robocopy.exe" -ArgumentList @(
            "`"$oldEdge`"", "`"$EncryptedDataDir`"",
            "/E", "/MOVE", "/R:0", "/W:0",
            "/NFL", "/NDL", "/NJH", "/NJS"
        ) -Wait -NoNewWindow
        Remove-Item $oldEdge -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Migrate local EdgeUserData to encrypted drive (if it's a real directory)
    $existing = Get-Item $LocalDataDir -Force -ErrorAction SilentlyContinue
    $isReparse = $false
    if ($existing) { $isReparse = ($existing.Attributes -band 0x400) -ne 0 }

    if ($isReparse) {
        Write-Host "Removing old symlink..." -ForegroundColor Yellow
        Remove-Item $LocalDataDir -Recurse -Force
    }
    elseif ($existing) {
        Write-Host "Migrating local user data to encrypted drive..." -ForegroundColor Cyan
        Start-Process -FilePath "robocopy.exe" -ArgumentList @(
            "`"$LocalDataDir`"", "`"$EncryptedDataDir`"",
            "/E", "/MOVE", "/R:0", "/W:0",
            "/NFL", "/NDL", "/NJH", "/NJS"
        ) -Wait -NoNewWindow

        # Clean up leftover symlinks and empty directories from migration
        Get-ChildItem $LocalDataDir -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { ($_.Attributes -band 0x400) -ne 0 } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem $LocalDataDir -Recurse -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { (Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0 } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Ensure local directory exists for cache targets
    if (-not (Test-Path $LocalDataDir)) {
        New-Item -ItemType Directory -Path $LocalDataDir -Force | Out-Null
    }

    # Override DataDir to encrypted location
    $script:DataDir = $EncryptedDataDir

    # Create cache symlinks (Y: → local)
    if (-not (New-LocalCacheSymlinks)) {
        Write-Host "Cache symlink creation failed." -ForegroundColor Red
        Dismount-Container -DriveLetter "Y" -Force
        return $false
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

foreach ($arg in $Arguments) {
    if ($arg -match "setup-password") { $doSetupPassword = $true }
    elseif ($arg -match "setup-encryption") { $doSetupEncryption = $true }
    elseif ($arg -notmatch "^--(setup-encryption|setup-password|help)$" -and $arg -ne "--%") {
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
$EdgeProcess = Start-Process -FilePath $EdgeExe -ArgumentList $allArgs -PassThru

if ($UseEncryption) {
    Write-Host "Edge is running. Close all Secure Edge windows to lock the encrypted drive." -ForegroundColor Cyan
    $EdgeProcess.WaitForExit()
    Write-Host "Secure Edge closed." -ForegroundColor Green
    Start-Sleep -Seconds 5
    Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Dismount-Container -DriveLetter "Y" -Force
}
