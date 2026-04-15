# Secure Edge Launcher for Windows
# Version 1.5 - Fixed Container Name Mismatch

param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Arguments = @()
)

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
# 【关键修复】：将这里的文件名改回 UserData.hc，以匹配加密模块的输出
$ContainerPath = Join-Path $ScriptDir "UserData.hc"

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

function Mount-EncryptedDataDir {
    param([Parameter(Mandatory=$true)][System.Security.SecureString]$Password)
    $mountedPath = Mount-Container -ContainerPath $ContainerPath -Password $Password -DriveLetter "Y"
    if ($mountedPath) {
        $script:DataDir = Join-Path $mountedPath "SecureEdge"
        if (-not (Test-Path $script:DataDir)) {
            New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
        }
        return $true
    }
    return $false
}

function Dismount-EncryptedDataDir {
    if ($EncryptionAvailable -and (Test-ContainerMounted -DriveLetter "Y")) {
        Write-Host "Dismounting Edge container safely..." -ForegroundColor Yellow
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

Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Dismount-EncryptedDataDir } | Out-Null

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

$allArgs = @("--user-data-dir=`"$script:DataDir`"", "--no-first-run") + $BrowserArgs
Write-Host "Launching Secure Edge..." -ForegroundColor Green
$process = Start-Process -FilePath $EdgeExe -ArgumentList $allArgs -PassThru

if ($UseEncryption) {
    Wait-Process -Id $process.Id -ErrorAction SilentlyContinue
    Dismount-EncryptedDataDir
}