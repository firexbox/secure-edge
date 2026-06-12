# Secure Edge Launcher for Windows
# Version 2.4 - Win32 CreateSymbolicLink (no placeholder files needed)

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
$script:DataDir = Join-Path $ScriptDir "EdgeUserData"
$script:EncryptedDir = $null
$ContainerPath = Join-Path $ScriptDir "UserData.hc"

# Privacy-sensitive files (file symlinks, dwFlags=0)
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

# Privacy-sensitive directories (directory symlinks, dwFlags=1)
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

    Write-Host "Symlinks ready." -ForegroundColor Green
    return $true
}

function Mount-EncryptedDataDir {
    param([Parameter(Mandatory=$true)][System.Security.SecureString]$Password)
    $mountedPath = Mount-Container -ContainerPath $ContainerPath -Password $Password -DriveLetter "Y"
    if (-not $mountedPath) { return $false }

    Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    $script:EncryptedDir = Join-Path $mountedPath "SecureProfile"
    if (-not (Test-Path $script:EncryptedDir)) {
        New-Item -ItemType Directory -Path $script:EncryptedDir -Force | Out-Null
    }

    $existing = Get-Item $script:DataDir -Force -ErrorAction SilentlyContinue
    if ($existing -and ($existing.Attributes -band 0x400)) {
        Write-Host "Removing junction..." -ForegroundColor Yellow
        Remove-Item $script:DataDir -Force
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
    }
    if (-not (Test-Path $script:DataDir)) {
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
    }

    $oldDir = Join-Path $mountedPath "SecureEdge"
    if (Test-Path $oldDir) {
        Write-Host "Migrating v2.2 data..." -ForegroundColor Yellow
        Start-Process -FilePath "robocopy.exe" -ArgumentList @(
            "`"$oldDir`"", "`"$script:EncryptedDir`"",
            "/E", "/MOVE", "/R:0", "/W:0",
            "/NFL", "/NDL", "/NJH", "/NJS"
        ) -Wait -NoNewWindow
        Remove-Item $oldDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not (New-SensitiveSymlinks)) {
        Write-Host "Symlink creation failed." -ForegroundColor Red
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
    "--media-cache-size=52428800",
    "--disable-gpu-shader-disk-cache"
) + $BrowserArgs
Write-Host "Launching Secure Edge..." -ForegroundColor Green
Start-Process -FilePath $EdgeExe -ArgumentList $allArgs | Out-Null

if ($UseEncryption) {
    Write-Host "Edge is running. Close all Edge windows to lock the encrypted drive." -ForegroundColor Cyan
    do {
        Start-Sleep -Seconds 3
        $hasWindow = Get-Process msedge -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }
    } while ($hasWindow)
    Write-Host "Edge windows closed." -ForegroundColor Green
    Start-Sleep -Seconds 5
    Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Dismount-Container -DriveLetter "Y" -Force
}
