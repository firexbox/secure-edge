# Secure Chromium Encryption Module
# Version 1.1 - VeraCrypt container integration (Bug fixed)

# Module configuration
$ModuleConfig = @{
    VeraCryptVersion = "1.25.9"
    VeraCryptDownloadUrl = "https://launchpad.net/veracrypt/trunk/1.25.9/+download/VeraCrypt_Portable_1.25.9.zip"
    ContainerExtension = ".hc"
    DefaultContainerSizeMB = 200
    MinContainerSizeMB = 50
    MaxContainerSizeMB = 2048
    MountLetter = "Z"
    TempMountLetter = "Y"
}

# Export functions
Export-ModuleMember -Variable ModuleConfig

# VeraCrypt paths
$script:VeraCryptDir = Join-Path $PSScriptRoot "veracrypt"
$script:VeraCryptExe = Join-Path $script:VeraCryptDir "VeraCrypt.exe"
$script:VeraCryptFormatExe = Join-Path $script:VeraCryptDir "VeraCrypt Format.exe"

# Container paths
$script:DefaultContainerName = "UserData$($ModuleConfig.ContainerExtension)"
$script:ContainerPath = Join-Path $PSScriptRoot $script:DefaultContainerName

function Test-VeraCryptInstalled {
    return (Test-Path $script:VeraCryptExe)
}

function Install-VeraCrypt {
    param(
        [Parameter(Mandatory=$false)]
        [string]$DownloadPath = $script:VeraCryptDir
    )
    
    Write-Host "Installing VeraCrypt portable..." -ForegroundColor Yellow
    
    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }
    
    $zipPath = Join-Path $DownloadPath "veracrypt.zip"
    
    Write-Host "Downloading VeraCrypt portable..." -ForegroundColor Cyan
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $ModuleConfig.VeraCryptDownloadUrl -OutFile $zipPath
    }
    catch {
        Write-Host "Failed to download VeraCrypt: $_" -ForegroundColor Red
        Write-Host "Please manually download from: $($ModuleConfig.VeraCryptDownloadUrl)" -ForegroundColor Yellow
        Write-Host "Extract to: $DownloadPath" -ForegroundColor Yellow
        return $false
    }
    
    Write-Host "Extracting VeraCrypt..." -ForegroundColor Cyan
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $DownloadPath)
    }
    catch {
        Write-Host "Failed to extract VeraCrypt: $_" -ForegroundColor Red
        Write-Host "Please manually extract $zipPath to $DownloadPath" -ForegroundColor Yellow
        return $false
    }
    
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    
    if (Test-VeraCryptInstalled) {
        Write-Host "VeraCrypt installed successfully." -ForegroundColor Green
        return $true
    } else {
        Write-Host "VeraCrypt installation verification failed." -ForegroundColor Red
        return $false
    }
}

function New-EncryptedContainer {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        
        [Parameter(Mandatory=$false)]
        [int]$SizeMB = $ModuleConfig.DefaultContainerSizeMB,
        
        [Parameter(Mandatory=$true)]
        [System.Security.SecureString]$Password,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("NTFS", "FAT")]
        [string]$Filesystem = "NTFS"
    )
    
    if ($SizeMB -lt $ModuleConfig.MinContainerSizeMB -or $SizeMB -gt $ModuleConfig.MaxContainerSizeMB) {
        Write-Host "Container size must be between $($ModuleConfig.MinContainerSizeMB) and $($ModuleConfig.MaxContainerSizeMB) MB." -ForegroundColor Red
        return $false
    }
    
    if (-not (Test-VeraCryptInstalled)) {
        Write-Host "VeraCrypt is not installed." -ForegroundColor Red
        return $false
    }
    
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    
    Write-Host "Creating encrypted container..." -ForegroundColor Yellow
    Write-Host "Path: $Path" -ForegroundColor Cyan
    Write-Host "Size: $SizeMB MB" -ForegroundColor Cyan
    Write-Host "Filesystem: $Filesystem" -ForegroundColor Cyan
    
    $formatArgs = @(
        "/create", "`"$Path`"",
        "/size", "${SizeMB}M",
        "/password", $plainPassword,
        "/hash", "sha512",
        "/encryption", "aes",
        "/filesystem", $Filesystem,
        "/dynamic",
        "/silent"
    )
    
    $plainPassword = $null
    
    try {
        $process = Start-Process -FilePath $script:VeraCryptFormatExe -ArgumentList $formatArgs -Wait -NoNewWindow -PassThru
        if ($process.ExitCode -eq 0) {
            Write-Host "Encrypted container created successfully." -ForegroundColor Green
            return $true
        } else {
            Write-Host "Failed to create container. Exit code: $($process.ExitCode)" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "Error creating container: $_" -ForegroundColor Red
        return $false
    }
}

function Mount-Container {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ContainerPath,
        
        [Parameter(Mandatory=$true)]
        [System.Security.SecureString]$Password,
        
        [Parameter(Mandatory=$false)]
        [string]$DriveLetter = $ModuleConfig.MountLetter,
        
        [Parameter(Mandatory=$false)]
        [switch]$ReadOnly
    )
    
    if (-not (Test-VeraCryptInstalled)) {
        Write-Host "VeraCrypt is not installed." -ForegroundColor Red
        return $null
    }
    
    if (-not (Test-Path $ContainerPath)) {
        Write-Host "Container file not found: $ContainerPath" -ForegroundColor Red
        return $null
    }
    
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    
    Write-Host "Mounting encrypted container..." -ForegroundColor Yellow
    Write-Host "Container: $ContainerPath" -ForegroundColor Cyan
    Write-Host "Drive: ${DriveLetter}:" -ForegroundColor Cyan
    
    $mountArgs = @(
        "/volume", "`"$ContainerPath`"",
        "/letter", $DriveLetter,
        "/password", $plainPassword,
        "/quit"
    )
    
    if ($ReadOnly) {
        $mountArgs += "/readonly"
    }
    
    $plainPassword = $null
    
    try {
        $process = Start-Process -FilePath $script:VeraCryptExe -ArgumentList $mountArgs -Wait -NoNewWindow -PassThru
        if ($process.ExitCode -eq 0) {
            $mountedPath = "${DriveLetter}:\"
            Write-Host "Container mounted successfully to $mountedPath" -ForegroundColor Green
            return $mountedPath
        } else {
            Write-Host "Failed to mount container. Exit code: $($process.ExitCode)" -ForegroundColor Red
            Write-Host "Possible causes:" -ForegroundColor Red
            Write-Host "  - Incorrect password" -ForegroundColor Red
            Write-Host "  - Drive letter already in use" -ForegroundColor Red
            Write-Host "  - Container file corrupted" -ForegroundColor Red
            return $null
        }
    }
    catch {
        Write-Host "Error mounting container: $_" -ForegroundColor Red
        return $null
    }
}

function Dismount-Container {
    param(
        [Parameter(Mandatory=$false)]
        [string]$DriveLetter = $ModuleConfig.MountLetter,
        
        [Parameter(Mandatory=$false)]
        [switch]$Force
    )
    
    if (-not (Test-VeraCryptInstalled)) {
        Write-Host "VeraCrypt is not installed." -ForegroundColor Red
        return $false
    }
    
    Write-Host "Dismounting encrypted container..." -ForegroundColor Yellow
    Write-Host "Drive: ${DriveLetter}:" -ForegroundColor Cyan
    
    $dismountArgs = @(
        "/dismount", $DriveLetter,
        "/quit"
    )
    
    if ($Force) {
        $dismountArgs += "/force"
    }
    
    try {
        $process = Start-Process -FilePath $script:VeraCryptExe -ArgumentList $dismountArgs -Wait -NoNewWindow -PassThru
        if ($process.ExitCode -eq 0) {
            Write-Host "Container dismounted successfully." -ForegroundColor Green
            return $true
        } else {
            Write-Host "Failed to dismount container. Exit code: $($process.ExitCode)" -ForegroundColor Red
            if ($Force -eq $false) {
                Write-Host "Try with -Force parameter if files are in use." -ForegroundColor Yellow
            }
            return $false
        }
    }
    catch {
        Write-Host "Error dismounting container: $_" -ForegroundColor Red
        return $false
    }
}

function Test-ContainerMounted {
    param(
        [Parameter(Mandatory=$false)]
        [string]$DriveLetter = $ModuleConfig.MountLetter
    )
    
    $drivePath = "${DriveLetter}:"
    return (Test-Path $drivePath)
}

function Get-ContainerInfo {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ContainerPath
    )
    
    if (-not (Test-Path $ContainerPath)) {
        Write-Host "Container file not found." -ForegroundColor Red
        return $null
    }
    
    $fileInfo = Get-Item $ContainerPath
    $sizeMB = [math]::Round($fileInfo.Length / 1MB, 2)
    
    return @{
        Path = $ContainerPath
        SizeBytes = $fileInfo.Length
        SizeMB = $sizeMB
        LastModified = $fileInfo.LastWriteTime
        Exists = $true
    }
}

function Migrate-ToEncryptedContainer {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SourcePath,
        
        [Parameter(Mandatory=$true)]
        [string]$ContainerPath,
        
        [Parameter(Mandatory=$true)]
        [System.Security.SecureString]$Password,
        
        [Parameter(Mandatory=$false)]
        [int]$ContainerSizeMB = $ModuleConfig.DefaultContainerSizeMB,
        
        [Parameter(Mandatory=$false)]
        [switch]$DeleteSource
    )
    
    if (-not (Test-Path $SourcePath)) {
        Write-Host "Source directory not found: $SourcePath" -ForegroundColor Red
        return $false
    }
    
    # 修复：处理空目录时对象为 null 的报错
    $sizeObj = Get-ChildItem -Path $SourcePath -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
    $sourceSize = if ($sizeObj.Sum -gt 0) { $sizeObj.Sum } else { 0 }
    $requiredSizeMB = [math]::Max([math]::Ceiling($sourceSize / 1MB * 1.2), $ContainerSizeMB)
    
    Write-Host "Migrating data to encrypted container..." -ForegroundColor Yellow
    Write-Host "Source: $SourcePath" -ForegroundColor Cyan
    Write-Host "Container: $ContainerPath" -ForegroundColor Cyan
    Write-Host "Required size: $requiredSizeMB MB" -ForegroundColor Cyan
    
    if (-not (New-EncryptedContainer -Path $ContainerPath -SizeMB $requiredSizeMB -Password $Password)) {
        return $false
    }
    
    $mountedPath = Mount-Container -ContainerPath $ContainerPath -Password $Password -DriveLetter $ModuleConfig.TempMountLetter
    if (-not $mountedPath) {
        return $false
    }
    
    Write-Host "Copying data..." -ForegroundColor Cyan
    try {
        $robocopyArgs = @(
            "`"$SourcePath`"",
            "`"$mountedPath`"",
            "/E",            
            "/COPYALL",      
            "/R:0",          
            "/W:0", 
            "/NFL",          
            "/NDL",          
            "/NJH",          
            "/NJS"           
        )
        
        $process = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -Wait -NoNewWindow -PassThru
        if ($process.ExitCode -lt 8) {  
            Write-Host "Data copied successfully." -ForegroundColor Green
        } else {
            Write-Host "Robocopy completed with warnings/errors. Exit code: $($process.ExitCode)" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Error copying data: $_" -ForegroundColor Red
        Dismount-Container -DriveLetter $ModuleConfig.TempMountLetter -Force
        return $false
    }
    
    if (-not (Dismount-Container -DriveLetter $ModuleConfig.TempMountLetter)) {
        Write-Host "Warning: Could not dismount temporary drive." -ForegroundColor Yellow
    }
    
    if ($DeleteSource) {
        Write-Host "Deleting original data..." -ForegroundColor Yellow
        try {
            Remove-Item -Path $SourcePath -Recurse -Force -ErrorAction Stop
            Write-Host "Original data deleted." -ForegroundColor Green
        }
        catch {
            Write-Host "Warning: Could not delete original data: $_" -ForegroundColor Yellow
        }
    }
    
    Write-Host "Migration completed successfully." -ForegroundColor Green
    return $true
}

function Get-EncryptionStatus {
    $status = @{
        VeraCryptInstalled = Test-VeraCryptInstalled
        ContainerExists = Test-Path $script:ContainerPath
        ContainerMounted = Test-ContainerMounted
        ContainerInfo = if (Test-Path $script:ContainerPath) { Get-ContainerInfo -ContainerPath $script:ContainerPath } else { $null }
        MountLetter = $ModuleConfig.MountLetter
    }
    
    return New-Object -TypeName PSObject -Property $status
}

function Initialize-Encryption {
    Write-Host "=== Secure Chromium Encryption Setup ===" -ForegroundColor Cyan
    Write-Host ""
    
    if (-not (Test-VeraCryptInstalled)) {
        Write-Host "VeraCrypt is not installed." -ForegroundColor Yellow
        $choice = Read-Host "Do you want to download and install VeraCrypt portable? (Y/N)"
        if ($choice -eq "Y" -or $choice -eq "y") {
            if (-not (Install-VeraCrypt)) {
                Write-Host "VeraCrypt installation failed. Encryption setup aborted." -ForegroundColor Red
                return $false
            }
        } else {
            Write-Host "Encryption setup aborted." -ForegroundColor Yellow
            return $false
        }
    }
    
    if (Test-Path $script:ContainerPath) {
        Write-Host "Encrypted container already exists: $script:ContainerPath" -ForegroundColor Green
        $choice = Read-Host "Do you want to create a new container? (Y/N)"
        if ($choice -ne "Y" -and $choice -ne "y") {
            Write-Host "Using existing container." -ForegroundColor Green
            return $true
        }
    }
    
    Write-Host ""
    Write-Host "Container size selection:" -ForegroundColor Cyan
    Write-Host "  1. Small (100 MB) - Basic browsing" -ForegroundColor Yellow
    Write-Host "  2. Medium (200 MB) - Recommended" -ForegroundColor Green
    Write-Host "  3. Large (500 MB) - Heavy browsing with extensions" -ForegroundColor Cyan
    Write-Host "  4. Custom size" -ForegroundColor Magenta
    
    $sizeChoice = Read-Host "Select option (1-4)"
    switch ($sizeChoice) {
        "1" { $sizeMB = 100 }
        "2" { $sizeMB = 200 }
        "3" { $sizeMB = 500 }
        "4" { 
            $customSize = Read-Host "Enter size in MB (50-2048)"
            if ($customSize -match '^\d+$' -and [int]$customSize -ge $ModuleConfig.MinContainerSizeMB -and [int]$customSize -le $ModuleConfig.MaxContainerSizeMB) {
                $sizeMB = [int]$customSize
            } else {
                Write-Host "Invalid size. Using default 200 MB." -ForegroundColor Red
                $sizeMB = 200
            }
        }
        default {
            Write-Host "Invalid choice. Using default 200 MB." -ForegroundColor Red
            $sizeMB = 200
        }
    }
    
    Write-Host ""
    Write-Host "Set container password:" -ForegroundColor Cyan
    $password1 = Read-Host "Enter password" -AsSecureString
    $password2 = Read-Host "Confirm password" -AsSecureString
    
    $BSTR1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password1)
    $plain1 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR1)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR1)
    
    $BSTR2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password2)
    $plain2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR2)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR2)
    
    if ($plain1 -ne $plain2) {
        Write-Host "Passwords do not match." -ForegroundColor Red
        return $false
    }
    
    $plain1 = $null
    $plain2 = $null
    
    Write-Host ""
    Write-Host "Creating encrypted container..." -ForegroundColor Yellow
    if (-not (New-EncryptedContainer -Path $script:ContainerPath -SizeMB $sizeMB -Password $password1)) {
        Write-Host "Failed to create container." -ForegroundColor Red
        return $false
    }
    
    Write-Host ""
    Write-Host "=== Encryption Setup Complete ===" -ForegroundColor Green
    Write-Host "Container created: $script:ContainerPath" -ForegroundColor Cyan
    Write-Host "Size: $sizeMB MB" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "1. Run 'sc.bat --setup-password' to set browser password" -ForegroundColor Green
    Write-Host "2. Your browser data will be stored in the encrypted container" -ForegroundColor Green
    
    return $true
}

Export-ModuleMember -Function *