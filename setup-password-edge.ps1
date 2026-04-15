# setup-password-edge.ps1
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigDir = Join-Path $ScriptDir "config_edge"
$PasswordFile = Join-Path $ConfigDir "password_edge.enc"

if (-not (Test-Path $ConfigDir)) { 
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null 
}

$p1 = Read-Host "Enter new Edge password" -AsSecureString
if (-not $p1) { exit 1 }
$p2 = Read-Host "Confirm password" -AsSecureString

$b1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1)
$s1 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b1)
$b2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2)
$s2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b2)

if ($s1 -ne $s2) { 
    Write-Host "Passwords do not match." -ForegroundColor Red
    exit 1 
}

$hasher = [System.Security.Cryptography.SHA256]::Create()
$hash = [System.BitConverter]::ToString($hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s1))).Replace("-", "").ToLower()

if (Test-Path $PasswordFile) { 
    Set-ItemProperty $PasswordFile -Name Attributes -Value 'Normal' -ErrorAction SilentlyContinue 
}

[System.IO.File]::WriteAllText($PasswordFile, $hash)
Set-ItemProperty $PasswordFile -Name Attributes -Value 'Hidden' -ErrorAction SilentlyContinue

Write-Host "Edge password set successfully!" -ForegroundColor Green