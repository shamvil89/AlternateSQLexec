[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Backup', 'Restore')]
    [string]$Operation
)

# Function to write logs in pipeline-friendly format
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $(
        switch ($Level) {
            'Info'    { 'White' }
            'Warning' { 'Yellow' }
            'Error'   { 'Red' }
        }
    )
}

function Get-SqlConnection {
    param (
        [string]$ServerInstance,
        [string]$Purpose
    )
    try {
        Write-Log "Configuring connection for $Purpose..."
        
        # Ask for authentication method
        $useWindowsAuth = Read-Host "Use Windows Authentication for $Purpose server? (Y/N)"
        $useWindowsAuth = $useWindowsAuth.ToUpper() -eq 'Y'

        if ($useWindowsAuth) {
            $connString = "Server=$ServerInstance;Trusted_Connection=True;TrustServerCertificate=True;"
            Write-Log "Using Windows Authentication"
        } else {
            $SqlUsername = Read-Host "Enter SQL Username for $Purpose server"
            $SqlPassword = Read-Host "Enter SQL Password for $Purpose server" -AsSecureString

            # Convert SecureString to plain text for connection string (only in memory)
            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SqlPassword)
            $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

            $connString = "Server=$ServerInstance;User Id=$SqlUsername;Password=$plainPassword;TrustServerCertificate=True;"
            $plainPassword = $null # Clear the password from memory
            Write-Log "Using SQL Authentication"
        }

        # Test connection
        Write-Log "Testing connection to $ServerInstance..."
        $testQuery = "SELECT @@VERSION"
        Invoke-Sqlcmd -ConnectionString $connString -Query $testQuery -ErrorAction Stop | Out-Null
        Write-Log "Connection successful!" -Level Info
        
        return $connString
    }
    catch {
        throw "Failed to create SQL connection for $Purpose server: $($_.Exception.Message)"
    }
}

function Backup-Database {
    param (
        [string]$ConnectionString,
        [string]$DatabaseName,
        [string]$BackupPath
    )
    try {
        # Generate backup filename
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $BackupFile = Join-Path $BackupPath "$($DatabaseName)_$timestamp.bak"

        # Ensure backup directory exists
        $backupDir = Split-Path $BackupFile -Parent
        if (-not (Test-Path $backupDir)) {
            Write-Log "Creating backup directory: $backupDir"
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }

        # Verify database exists
        $checkDbQuery = "SELECT name FROM sys.databases WHERE name = '$DatabaseName'"
        $existingDb = Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $checkDbQuery -ErrorAction Stop
        
        if (-not $existingDb) {
            throw "Database '$DatabaseName' does not exist on source server"
        }

        # Build and execute backup command
        $backupCmd = "BACKUP DATABASE [$DatabaseName] TO DISK = N'$BackupFile' WITH STATS = 10"
        Write-Log "Starting backup of database '$DatabaseName'..."
        Write-Log "Backup will be saved to: $BackupFile"
        
        Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $backupCmd -QueryTimeout 3600 -ErrorAction Stop
        Write-Log "Database backup completed successfully!"
        Write-Log "Backup file created at: $BackupFile"
        
        return $BackupFile
    }
    catch {
        throw "Backup failed: $($_.Exception.Message)"
    }
}

function Restore-Database {
    param (
        [string]$ConnectionString,
        [string]$DatabaseName,
        [string]$BackupFile
    )
    try {
        # Verify backup file exists
        if (-not (Test-Path $BackupFile)) {
            throw "Backup file not found: $BackupFile"
        }

        # Set paths
        $DataFilePath = "$(Split-Path $BackupFile -Parent)\Data"
        $LogFilePath = "$(Split-Path $BackupFile -Parent)\Log"

        # Ensure directories exist
        foreach ($path in @($DataFilePath, $LogFilePath)) {
            if (-not (Test-Path $path)) {
                Write-Log "Creating directory: $path"
                New-Item -ItemType Directory -Path $path -Force | Out-Null
            }
        }

        # Check if database exists
        $checkDbQuery = "SELECT name FROM sys.databases WHERE name = '$DatabaseName'"
        $existingDb = Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $checkDbQuery -ErrorAction Stop
        
        if ($existingDb) {
            Write-Log "Database '$DatabaseName' exists on target server. It will be dropped." -Level Warning
            $dropQuery = "ALTER DATABASE [$DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DatabaseName]"
            Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $dropQuery -ErrorAction Stop
        }

        # Get logical file names from backup
        Write-Log "Reading backup file information..."
        $fileListQuery = "RESTORE FILELISTONLY FROM DISK = N'$BackupFile'"
        $fileList = Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $fileListQuery -ErrorAction Stop
        
        # Build the MOVE statements
        $moveStatements = @()
        foreach ($file in $fileList) {
            $logicalName = $file.LogicalName
            $type = $file.Type
            
            $targetPath = if ($type -eq 'L') { $LogFilePath } else { $DataFilePath }
            $newFileName = if ($type -eq 'L') {
                "${DatabaseName}_log.ldf"
            } else {
                "${DatabaseName}.mdf"
            }
            
            $fullPath = Join-Path $targetPath $newFileName
            $moveStatements += "MOVE N'$logicalName' TO N'$fullPath'"
        }

        # Execute restore
        $restoreQuery = @"
        RESTORE DATABASE [$DatabaseName] 
        FROM DISK = N'$BackupFile' 
        WITH FILE = 1,
        $(($moveStatements) -join ",`n    "),
        STATS = 10
"@

        Write-Log "Starting restore of database '$DatabaseName'..."
        Write-Log "Using backup file: $BackupFile"
        
        Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $restoreQuery -QueryTimeout 3600 -ErrorAction Stop
        Write-Log "Database restore completed successfully!"
    }
    catch {
        throw "Restore failed: $($_.Exception.Message)"
    }
}

try {
    Write-Log "Starting Database $Operation Process" -Level Info
    
    if ($Operation -eq 'Backup') {
        # Get source server details
        $sourceServer = Read-Host "Enter source SQL Server instance name"
        $sourceDb = Read-Host "Enter source database name"
        $backupPath = Read-Host "Enter backup file location (folder path)"
        
        # Get source connection and perform backup
        $sourceConn = Get-SqlConnection -ServerInstance $sourceServer -Purpose "Source"
        $backupFile = Backup-Database -ConnectionString $sourceConn -DatabaseName $sourceDb -BackupPath $backupPath
        
        Write-Log "Backup completed successfully. Backup file: $backupFile" -Level Info
    }
    else {
        # Get target server details
        $backupPath = Read-Host "Enter backup file location (folder path)"
        $backupFile = Read-Host "Enter backup file name (including .bak extension)"
        $fullBackupPath = Join-Path $backupPath $backupFile
        
        $targetServer = Read-Host "Enter target SQL Server instance name"
        $targetDb = Read-Host "Enter target database name"
        
        # Get target connection and perform restore
        $targetConn = Get-SqlConnection -ServerInstance $targetServer -Purpose "Target"
        Restore-Database -ConnectionString $targetConn -DatabaseName $targetDb -BackupFile $fullBackupPath
        
        Write-Log "Restore completed successfully" -Level Info
    }
    
    exit 0
}
catch {
    Write-Log "Error occurred during $Operation process:" -Level Error
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