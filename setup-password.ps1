# Password setup utility for Secure Chromium on Windows
# Final Version - PS 5.1 Compatible & Antivirus Resilient

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigDir = Join-Path $ScriptDir "config"
$PasswordFile = Join-Path $ConfigDir "password.enc"
$DataDir = Join-Path $ScriptDir "UserData"

# 1. 确保配置文件夹存在
if (-not (Test-Path $ConfigDir)) { 
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null 
}

$password1 = Read-Host "Enter new password" -AsSecureString
if (-not $password1) { exit 1 }
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

# 2. 计算 SHA256 哈希值
$hasher = [System.Security.Cryptography.SHA256]::Create()
$hashBytes = $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($plain1))
$hash = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLower()

$plain1 = $null; $plain2 = $null

# 3. 剥夺旧文件的隐藏属性（如果存在），防止权限被拒
if (Test-Path $PasswordFile) {
    Set-ItemProperty -Path $PasswordFile -Name Attributes -Value 'Normal' -ErrorAction SilentlyContinue
}

# 4. 强制覆写写入哈希值
try {
    New-Item -Path $PasswordFile -ItemType File -Value $hash -Force | Out-Null
} catch {
    Write-Host "Error writing file: $_" -ForegroundColor Red
    exit 1
}

# 5. 防杀软检测：短暂延迟后确认文件是否存活
Start-Sleep -Milliseconds 200
if (-not (Test-Path $PasswordFile)) {
    Write-Host "【严重错误】密码文件刚创建就被删除了！" -ForegroundColor Red
    Write-Host "请检查你的杀毒软件（如 360/火绒/Windows Defender），将其加入白名单。" -ForegroundColor Yellow
    exit 1
}

# 6. 安全赋予隐藏属性
Set-ItemProperty -Path $PasswordFile -Name Attributes -Value 'Hidden' -ErrorAction SilentlyContinue

# 7. 确保数据目录存在
if (-not (Test-Path $DataDir)) { 
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null 
}

Write-Host "Password set successfully!" -ForegroundColor Green