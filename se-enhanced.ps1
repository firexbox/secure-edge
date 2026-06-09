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

function Clear-EdgeCache {
    param([string]$EdgeDataDir)
    if (-not $EdgeDataDir -or -not (Test-Path $EdgeDataDir)) { return }

    Write-Host "Cleaning Edge cache to reduce container size..." -ForegroundColor Cyan
    $cachePaths = @(
        # GPU / Shader caches
        "$EdgeDataDir\Default\Cache",
        "$EdgeDataDir\Default\Code Cache",
        "$EdgeDataDir\Default\DawnWebGPUCache",
        "$EdgeDataDir\Default\DawnGraphiteCache",
        "$EdgeDataDir\Default\GPUCache",
        "$EdgeDataDir\Default\image_cache",
        "$EdgeDataDir\GrShaderCache",
        "$EdgeDataDir\ShaderCache",
        "$EdgeDataDir\GraphiteDawnCache",
        # Service Worker / Storage temp
        "$EdgeDataDir\Default\Service Worker",
        "$EdgeDataDir\Default\Session Storage",
        "$EdgeDataDir\Default\shared_proto_db",
        # Jump list icons
        "$EdgeDataDir\Default\JumpListIconsRecentClosed",
        "$EdgeDataDir\Default\JumpListIconsTopSites",
        # Media / Optimization
        "$EdgeDataDir\Default\VideoDecodeStats",
        "$EdgeDataDir\Default\optimization_guide_hint_cache_store",
        "$EdgeDataDir\Default\MediaFoundationWidevineCdm",
        # Component / Extension crx
        "$EdgeDataDir\component_crx_cache",
        # Metrics / Crash
        "$EdgeDataDir\BrowserMetrics",
        "$EdgeDataDir\BrowserMetrics-spare.pma",
        "$EdgeDataDir\Crashpad",
        # Edge 内部组件缓存
        "$EdgeDataDir\Subresource Filter",
        "$EdgeDataDir\SafetyTips",
        "$EdgeDataDir\Crowd Deny",
        "$EdgeDataDir\FileTypePolicies",
        "$EdgeDataDir\FirstPartySetsPreloaded",
        "$EdgeDataDir\TrustTokenKeyCommitments",
        "$EdgeDataDir\TpcdMetadata",
        "$EdgeDataDir\ZxcvbnData",
        "$EdgeDataDir\OriginTrials",
        "$EdgeDataDir\AutofillStates",
        "$EdgeDataDir\hyphen-data",
        "$EdgeDataDir\PKIMetadata",
        "$EdgeDataDir\WidevineCdm",
        "$EdgeDataDir\MEIPreload",
        # Edge 功能组件数据（按需自动重建，共约 640 MB）
        "$EdgeDataDir\EdgeTranslateKitLanguagePack",
        "$EdgeDataDir\EdgeLLMRuntime",
        "$EdgeDataDir\Edge Shopping",
        "$EdgeDataDir\Safe Browsing",
        "$EdgeDataDir\EdgeLanguageDetectionModel",
        "$EdgeDataDir\Speech Recognition",
        "$EdgeDataDir\Edge Sidebar",
        "$EdgeDataDir\Edge Signal Triggers",
        "$EdgeDataDir\Edge Entity Extraction",
        "$EdgeDataDir\SmartScreen",
        "$EdgeDataDir\Well Known Domains",
        "$EdgeDataDir\Typosquatting"
    )
    $freed = 0
    foreach ($p in $cachePaths) {
        $resolved = [System.IO.Path]::GetFullPath($p)
        if (Test-Path $resolved) {
            try {
                $size = (Get-ChildItem $resolved -Recurse -File -ErrorAction Stop | Measure-Object -Property Length -Sum).Sum
                Remove-Item $resolved -Recurse -Force -ErrorAction Stop
                $freed += $size
                Write-Host "  Cleaned: $([System.IO.Path]::GetFileName($resolved)) ($([math]::Round($size/1MB, 1)) MB)" -ForegroundColor Gray
            } catch {
                Write-Host "  Skipped (locked): $([System.IO.Path]::GetFileName($resolved))" -ForegroundColor DarkGray
            }
        }
    }
    Write-Host "Cache cleanup freed $([math]::Round($freed/1MB, 1)) MB" -ForegroundColor Green
}

function Dismount-EncryptedDataDir {
    if ($EncryptionAvailable -and (Test-ContainerMounted -DriveLetter "Y")) {
        Clear-EdgeCache -EdgeDataDir $script:DataDir
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

# 最小化控制台窗口
try {
    Add-Type -Name Window -Namespace Console -MemberDefinition '
        [DllImport("Kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("User32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    ' -ErrorAction Stop
    $hwnd = [Console.Window]::GetConsoleWindow()
    [Console.Window]::ShowWindow($hwnd, 6) | Out-Null
} catch {
    Write-Host "Unable to minimize window: $_" -ForegroundColor DarkGray
}

#$allArgs = @("--user-data-dir=`"$script:DataDir`"", "--no-first-run") + $BrowserArgs
$allArgs = @(
    "--user-data-dir=`"$script:DataDir`"",
    "--no-first-run",
    "--disk-cache-size=104857600",      # 强制常规缓存最大为 100MB
    "--media-cache-size=52428800",      # 强制音视频缓存最大为 50MB
    "--disable-gpu-shader-disk-cache",  # 禁用显卡着色器磁盘缓存（非常占空间）
    "--disable-features=Translate"      # 禁用内置翻译，阻止 ~600MB 语言包下载
) + $BrowserArgs
Write-Host "Launching Secure Edge..." -ForegroundColor Green
$process = Start-Process -FilePath $EdgeExe -ArgumentList $allArgs -PassThru

# 启动加密盘根目录下的附加程序
if ($UseEncryption) {
    $encryptedRoot = (Get-PSDrive "Y").Root
    if (-not $encryptedRoot) { $encryptedRoot = "Y:\" }

    $mihomoBat = Join-Path $encryptedRoot "mh-ep\mihomo-ep_reStart.bat"
    if (Test-Path $mihomoBat) {
        Write-Host "Launching mihomo-ep..." -ForegroundColor Green
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"`"$mihomoBat`"`"" -WindowStyle Hidden
    } else {
        Write-Host "mihomo-ep not found: $mihomoBat" -ForegroundColor Yellow
    }

    $electermExe = Join-Path $encryptedRoot "electerm\electerm.exe"
    if (Test-Path $electermExe) {
        Write-Host "Launching electerm..." -ForegroundColor Green
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $electermExe
        $psi.UseShellExecute = $false
        $psi.RedirectStandardError = $true
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    } else {
        Write-Host "electerm not found: $electermExe" -ForegroundColor Yellow
    }
}

if ($UseEncryption) {
    Wait-Process -Id $process.Id -ErrorAction SilentlyContinue
    Dismount-EncryptedDataDir
}