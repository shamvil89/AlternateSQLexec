[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$SourceInstanceName,
    
    [Parameter(Mandatory=$true)]
    [string]$SourceDatabaseName,
    
    [Parameter(Mandatory=$true)]
    [string]$TargetInstanceName,
    
    [Parameter(Mandatory=$true)]
    [string]$TargetDatabaseName,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('Full', 'CopyOnly')]
    [string]$BackupType = 'CopyOnly',
    
    [Parameter(Mandatory=$false)]
    [switch]$UseWindowsAuth
)

# Function to write logs with color
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'White' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
    }
    Write-Host "[$timestamp] $Message" -ForegroundColor $color
}

# Function to get SQL connection string
function Get-SqlConnection {
    param (
        [string]$ServerInstance,
        [string]$Purpose,
        [bool]$UseWindowsAuth
    )
    try {
        Write-Log "Configuring connection for $Purpose server ($ServerInstance)..."
        
        if ($UseWindowsAuth) {
            $connString = "Server=$ServerInstance;Trusted_Connection=True;TrustServerCertificate=True;"
            Write-Log "Using Windows Authentication"
        } else {
            $SqlUsername = Read-Host "Enter SQL Username for $Purpose server"
            $SqlPassword = Read-Host "Enter SQL Password for $Purpose server" -AsSecureString
            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SqlPassword)
            $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
            
            $connString = "Server=$ServerInstance;User Id=$SqlUsername;Password=$plainPassword;TrustServerCertificate=True;"
            $plainPassword = $null
            Write-Log "Using SQL Authentication"
        }
        
        # Test connection
        Write-Log "Testing connection to $ServerInstance..."
        $testQuery = "SELECT @@VERSION"
        Invoke-Sqlcmd -ConnectionString $connString -Query $testQuery -ErrorAction Stop | Out-Null
        Write-Log "Connection successful!"
        
        return $connString
    }
    catch {
        throw "Failed to create SQL connection for $Purpose server: $($_.Exception.Message)"
    }
}

try {
    # Get source connection first to verify database
    $sourceConn = Get-SqlConnection -ServerInstance $SourceInstanceName -Purpose "Source" -UseWindowsAuth $UseWindowsAuth

    # Verify source database exists
    Write-Log "Verifying source database exists..."
    $checkDbQuery = "SELECT name FROM sys.databases WHERE name = '$SourceDatabaseName'"
    $sourceDb = Invoke-Sqlcmd -ConnectionString $sourceConn -Query $checkDbQuery
    if (-not $sourceDb) {
        throw "Source database '$SourceDatabaseName' does not exist on $SourceInstanceName"
    }

    # Get SQL Server default paths for suggestions
    $defaultBackupPath = Invoke-Sqlcmd -ConnectionString $sourceConn -Query "SELECT SERVERPROPERTY('InstanceDefaultBackupPath') as BackupPath"
    Write-Log "Default backup path is: $($defaultBackupPath.BackupPath)"
    
    # Prompt for backup location
    do {
        $BackupPath = Read-Host "Enter backup file location (press Enter for default: $($defaultBackupPath.BackupPath))"
        if ([string]::IsNullOrWhiteSpace($BackupPath)) {
            $BackupPath = $defaultBackupPath.BackupPath
        }
        
        # Verify the path exists and is accessible
        if (-not (Test-Path $BackupPath)) {
            $create = Read-Host "Directory doesn't exist. Create it? (Y/N)"
            if ($create.ToUpper() -eq 'Y') {
                New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
            } else {
                Write-Log "Please provide a valid path" -Level Warning
                continue
            }
        }
        
        # Test if SQL Server can access the path
        $testBackupCmd = "BACKUP DATABASE [master] TO DISK = N'$BackupPath\test.bak' WITH INIT, SKIP, NOUNLOAD, STATS = 10, COPY_ONLY"
        try {
            Invoke-Sqlcmd -ConnectionString $sourceConn -Query $testBackupCmd -ErrorAction Stop
            Remove-Item "$BackupPath\test.bak" -Force -ErrorAction SilentlyContinue
            break
        }
        catch {
            Write-Log "SQL Server cannot access this location. Please choose a different path." -Level Warning
            Write-Log $_.Exception.Message -Level Warning
        }
    } while ($true)

    # Generate backup filename
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $BackupFile = Join-Path $BackupPath "$($SourceDatabaseName)_$timestamp.bak"

    # Perform backup
    Write-Log "Starting backup of database '$SourceDatabaseName' from $SourceInstanceName..."
    $backupCmd = if ($BackupType -eq 'CopyOnly') {
        "BACKUP DATABASE [$SourceDatabaseName] TO DISK = N'$BackupFile' WITH COPY_ONLY, STATS = 10, INIT"
    } else {
        "BACKUP DATABASE [$SourceDatabaseName] TO DISK = N'$BackupFile' WITH STATS = 10, INIT"
    }
    
    Invoke-Sqlcmd -ConnectionString $sourceConn -Query $backupCmd -QueryTimeout 3600 -ErrorAction Stop
    Write-Log "Backup completed successfully!"

    # Verify backup file exists
    if (-not (Test-Path $BackupFile)) {
        throw "Backup file was not created at: $BackupFile"
    }

    # Get target connection
    $targetConn = Get-SqlConnection -ServerInstance $TargetInstanceName -Purpose "Target" -UseWindowsAuth $UseWindowsAuth

    # Get logical file names from backup
    Write-Log "Reading backup file information..."
    $fileListQuery = "RESTORE FILELISTONLY FROM DISK = N'$BackupFile'"
    $fileList = Invoke-Sqlcmd -ConnectionString $targetConn -Query $fileListQuery -ErrorAction Stop

    # Get default paths for target
    $defaultDataPath = Invoke-Sqlcmd -ConnectionString $targetConn -Query "SELECT SERVERPROPERTY('InstanceDefaultDataPath') as DataPath"
    $defaultLogPath = Invoke-Sqlcmd -ConnectionString $targetConn -Query "SELECT SERVERPROPERTY('InstanceDefaultLogPath') as LogPath"
    
    Write-Log "Default data path is: $($defaultDataPath.DataPath)"
    Write-Log "Default log path is: $($defaultLogPath.LogPath)"

    # Prompt for data file location
    do {
        $DataFilePath = Read-Host "Enter data file location (press Enter for default: $($defaultDataPath.DataPath))"
        if ([string]::IsNullOrWhiteSpace($DataFilePath)) {
            $DataFilePath = $defaultDataPath.DataPath
        }
        
        if (-not (Test-Path $DataFilePath)) {
            $create = Read-Host "Directory doesn't exist. Create it? (Y/N)"
            if ($create.ToUpper() -eq 'Y') {
                New-Item -ItemType Directory -Path $DataFilePath -Force | Out-Null
                break
            }
        } else {
            break
        }
    } while ($true)

    # Prompt for log file location
    do {
        $LogFilePath = Read-Host "Enter log file location (press Enter for default: $($defaultLogPath.LogPath))"
        if ([string]::IsNullOrWhiteSpace($LogFilePath)) {
            $LogFilePath = $defaultLogPath.LogPath
        }
        
        if (-not (Test-Path $LogFilePath)) {
            $create = Read-Host "Directory doesn't exist. Create it? (Y/N)"
            if ($create.ToUpper() -eq 'Y') {
                New-Item -ItemType Directory -Path $LogFilePath -Force | Out-Null
                break
            }
        } else {
            break
        }
    } while ($true)

    # Check if target database exists
    $checkTargetQuery = "SELECT name FROM sys.databases WHERE name = '$TargetDatabaseName'"
    $targetDb = Invoke-Sqlcmd -ConnectionString $targetConn -Query $checkTargetQuery
    if ($targetDb) {
        Write-Log "Target database exists. Setting to single user mode and dropping..." -Level Warning
        $dropQuery = @"
            IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$TargetDatabaseName')
            BEGIN
                ALTER DATABASE [$TargetDatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
                DROP DATABASE [$TargetDatabaseName];
            END
"@
        Invoke-Sqlcmd -ConnectionString $targetConn -Query $dropQuery -ErrorAction Stop
    }

    # Build MOVE statements
    $moveStatements = @()
    foreach ($file in $fileList) {
        $logicalName = $file.LogicalName
        $type = $file.Type
        $targetPath = if ($type -eq 'L') { $LogFilePath } else { $DataFilePath }
        $newFileName = if ($type -eq 'L') {
            "$($TargetDatabaseName)_log.ldf"
        } else {
            "$($TargetDatabaseName).mdf"
        }
        $fullPath = Join-Path $targetPath $newFileName
        $moveStatements += "MOVE N'$logicalName' TO N'$fullPath'"
    }

    # Execute restore
    Write-Log "Starting restore of database '$TargetDatabaseName' on $TargetInstanceName..."
    $restoreQuery = @"
RESTORE DATABASE [$TargetDatabaseName] 
FROM DISK = N'$BackupFile' 
WITH FILE = 1,
    $(($moveStatements) -join ",`n    "),
    STATS = 10,
    REPLACE
"@

    Invoke-Sqlcmd -ConnectionString $targetConn -Query $restoreQuery -QueryTimeout 3600 -ErrorAction Stop
    Write-Log "Database restore completed successfully!"

    # Ask if user wants to keep the backup file
    $keepBackup = Read-Host "Do you want to keep the backup file? (Y/N)"
    if ($keepBackup.ToUpper() -ne 'Y') {
        Remove-Item $BackupFile -Force
        Write-Log "Backup file removed"
    } else {
        Write-Log "Backup file kept at: $BackupFile"
    }

    Write-Log "Database refresh completed successfully!" -Level Info
}
catch {
    Write-Log $_.Exception.Message -Level Error
    Write-Log $_.Exception.StackTrace -Level Error
    exit 1
}
finally {
    # Cleanup
    if ($sourceConn) { $sourceConn = $null }
    if ($targetConn) { $targetConn = $null }
    [System.GC]::Collect()
} 