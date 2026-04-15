# Secure Chromium Launcher for Windows
# Version 3.1 - Enhanced with VeraCrypt encryption support (Bug fixed)

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
        # 加入 -DisableNameChecking 屏蔽未批准动词的强迫症警告
        Import-Module $EncryptionModule -Force -DisableNameChecking -ErrorAction Stop
        $EncryptionStatus = Get-EncryptionStatus -ErrorAction Stop
        $EncryptionAvailable = $true
        Write-Host "✓ Encryption functions verified" -ForegroundColor Green
    }
    catch {
        Write-Host "✗ Encryption not available: $_" -ForegroundColor Red
        $EncryptionAvailable = $false
    }
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigDir = Join-Path $ScriptDir "config"
$PasswordFile = Join-Path $ConfigDir "password.enc"
$script:DataDir = Join-Path $ScriptDir "UserData"
$ContainerPath = Join-Path $ScriptDir "UserData.hc"
$ChromiumExe = ""

function Find-Chromium {
    $relativePaths = @("chromium\chrome.exe", "chrome-win\chrome.exe", "chrome.exe", "chromium.exe")
    foreach ($path in $relativePaths) {
        $fullPath = Join-Path $ScriptDir $path
        if (Test-Path $fullPath) { return $fullPath }
    }
    $systemPaths = @("chrome.exe", "chromium.exe", "msedge.exe")
    foreach ($exe in $systemPaths) {
        $exePath = (Get-Command $exe -ErrorAction SilentlyContinue).Source
        if ($exePath) { return $exePath }
    }
    Write-Host "ERROR: Chromium/Chrome not found." -ForegroundColor Red
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
    if (-not $EncryptionAvailable) { return $false }
    
    $mountedPath = Mount-Container -ContainerPath $ContainerPath -Password $Password -DriveLetter "Z"
    if ($mountedPath) {
        $script:DataDir = Join-Path $mountedPath "SecureChromium"
        if (-not (Test-Path $script:DataDir)) {
            New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
        }
        Write-Host "Using encrypted data directory: $script:DataDir" -ForegroundColor Green
        return $true
    }
    return $false
}

function Dismount-EncryptedDataDir {
    if (-not $EncryptionAvailable) { return $true }
    if (Test-ContainerMounted -DriveLetter "Z") {
        Write-Host "Dismounting encrypted container safely..." -ForegroundColor Yellow
        $retries = 0
        while ($retries -lt 5) {
            if (Dismount-Container -DriveLetter "Z") { return $true }
            Write-Host "Files in use. Waiting for Chromium background processes to exit... ($retries/5)" -ForegroundColor Yellow
            Start-Sleep -Seconds 3
            $retries++
        }
        Write-Host "Warning: Could not gracefully dismount container. Please ensure browser is fully closed." -ForegroundColor Red
        return $false
    }
    return $true
}

Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Dismount-EncryptedDataDir
} | Out-Null

# 提取属于浏览器的真实参数，过滤掉脚本自带的开关
$BrowserArgs = @()
foreach ($arg in $Arguments) {
    if ($arg -match "^--(setup-encryption|migrate-to-encryption|setup-password|disable-password-auth|encryption-status|help)$" -or $arg -eq "-h") {
        continue
    }
    $BrowserArgs += $arg
}

# 处理脚本自身的所有控制指令
foreach ($arg in $Arguments) {
    if ($arg -eq "--setup-encryption") {
        if ($EncryptionAvailable) { Initialize-Encryption }
        exit $LASTEXITCODE
    }
    
    if ($arg -eq "--migrate-to-encryption") {
        if (-not $EncryptionAvailable) {
            Write-Host "Encryption module not available." -ForegroundColor Red
            exit 1
        }
        if (-not (Test-Path $script:DataDir)) {
            Write-Host "No existing UserData directory found." -ForegroundColor Yellow
            exit 1
        }
        $password1 = Read-Host "Enter encryption password" -AsSecureString
        $password2 = Read-Host "Confirm password" -AsSecureString
        
        $BSTR1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password1)
        $plain1 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR1)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR1)
        
        $BSTR2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password2)
        $plain2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR2)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR2)
        
        if ($plain1 -ne $plain2) {
            Write-Host "Passwords do not match." -ForegroundColor Red
            exit 1
        }
        $plain1 = $null; $plain2 = $null
        
        Write-Host "Migrating to encrypted container..." -ForegroundColor Yellow
        if (Migrate-ToEncryptedContainer -SourcePath $script:DataDir -ContainerPath $ContainerPath -Password $password1 -DeleteSource) {
            Write-Host "Migration successful. Please restart Secure Chromium." -ForegroundColor Green
        } else {
            Write-Host "Migration failed." -ForegroundColor Red
        }
        exit $LASTEXITCODE
    }
    
    if ($arg -eq "--setup-password") {
        & "$ScriptDir\setup-password.ps1"
        exit $LASTEXITCODE
    }
    
    if ($arg -eq "--encryption-status") {
        Write-Host "=== Secure Chromium Encryption Status ===" -ForegroundColor Cyan
        if ($EncryptionAvailable) {
            try {
                $status = Get-EncryptionStatus -ErrorAction Stop
                Write-Host "VeraCrypt installed: $($status.VeraCryptInstalled)" -ForegroundColor $(if ($status.VeraCryptInstalled) { "Green" } else { "Red" })
                Write-Host "Container exists: $($status.ContainerExists)" -ForegroundColor $(if ($status.ContainerExists) { "Green" } else { "Yellow" })
                Write-Host "Container mounted: $($status.ContainerMounted)" -ForegroundColor $(if ($status.ContainerMounted) { "Green" } else { "Gray" })
                if ($status.ContainerInfo) {
                    Write-Host "  Size: $($status.ContainerInfo.SizeMB) MB" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "Failed to get encryption status: $_" -ForegroundColor Red
            }
        } else {
            Write-Host "Encryption module not available." -ForegroundColor Red
        }
        exit 0
    }
    
    if ($arg -eq "--disable-password-auth") {
        $ChromiumExe = Find-Chromium
        if (-not $ChromiumExe) { exit 1 }
        $allArgs = @("--user-data-dir=`"$script:DataDir`"") + $BrowserArgs
        Start-Process -FilePath $ChromiumExe -ArgumentList $allArgs -NoNewWindow:$false
        exit 0
    }
    
    if ($arg -eq "--help" -or $arg -eq "-h") {
        Write-Host "Secure Chromium (sc) for Windows - Enhanced Edition"
        Write-Host "Usage: sc-enhanced [OPTIONS] [CHROMIUM_ARGUMENTS]"
        Write-Host "  --setup-password         Set or change browser password"
        Write-Host "  --setup-encryption       Set up VeraCrypt encrypted container"
        Write-Host "  --migrate-to-encryption  Migrate existing data to encrypted container"
        Write-Host "  --encryption-status      Show encryption status"
        Write-Host "  --disable-password-auth  Launch without password"
        exit 0
    }
}

# Main execution
$ChromiumExe = Find-Chromium
if (-not $ChromiumExe) { exit 1 }

if (Test-Path $PasswordFile) {
    $password = Read-Host "Enter password" -AsSecureString
    if (-not $password) { exit 1 }
    
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    
    $storedHash = (Get-Content $PasswordFile -Raw).Trim()
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $inputHash = [System.BitConverter]::ToString(
        $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($plainPassword))
    ).Replace("-", "").ToLower()
    
    $plainPassword = $null
    
    if ($inputHash -ne $storedHash) {
        Write-Host "Incorrect password." -ForegroundColor Red
        exit 1
    }
    
    if ($UseEncryption) {
        Write-Host "Mounting encrypted container..." -ForegroundColor Yellow
        if (-not (Mount-EncryptedDataDir -Password $password)) { exit 1 }
    }
} else {
    Write-Host "No password set. Run 'sc-enhanced.bat --setup-password' first." -ForegroundColor Yellow
    
    $response = Read-Host "Do you want to set a password now? (y/N)"
    if ($response -eq "y" -or $response -eq "Y") {
        & "$ScriptDir\setup-password.ps1"
        exit $LASTEXITCODE
    } else {
        exit 0
    }
}

if (-not $UseEncryption -and -not (Test-Path $script:DataDir)) {
    New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
}

$allArgs = @("--user-data-dir=`"$script:DataDir`"") + $BrowserArgs
Write-Host "Launching Secure Chromium..." -ForegroundColor Green
$process = Start-Process -FilePath $ChromiumExe -ArgumentList $allArgs -NoNewWindow:$false -PassThru

if ($UseEncryption) {
    Write-Host "Waiting for main browser process..." -ForegroundColor Cyan
    Wait-Process -Id $process.Id -ErrorAction SilentlyContinue
    Dismount-EncryptedDataDir
}
exit 0