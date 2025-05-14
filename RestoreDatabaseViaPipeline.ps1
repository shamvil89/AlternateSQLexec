[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Backup', 'Restore')]
    [string]$Operation,

    [Parameter(Mandatory=$true)]
    [string]$DatabaseName,
    
    [Parameter(Mandatory=$true)]
    [string]$ServerInstance,
    
    [Parameter(Mandatory=$false)]
    [string]$BackupFile,
    
    [Parameter(Mandatory=$false)]
    [string]$DataFilePath,
    
    [Parameter(Mandatory=$false)]
    [string]$LogFilePath,

    [Parameter(Mandatory=$false)]
    [string]$SqlUsername,

    [Parameter(Mandatory=$false)]
    [System.Security.SecureString]$SqlPassword,

    [Parameter(Mandatory=$false)]
    [switch]$UseWindowsAuth = $false,

    [Parameter(Mandatory=$false)]
    [int]$CommandTimeout = 3600,

    [Parameter(Mandatory=$false)]
    [switch]$OverwriteExisting = $false,

    [Parameter(Mandatory=$false)]
    [ValidateSet('Full', 'Differential', 'Log')]
    [string]$BackupType = 'Full',

    [Parameter(Mandatory=$false)]
    [string]$Description
)

# Function to write logs in pipeline-friendly format
function Write-PipelineLog {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        'Info'    { Write-Host "##[info][$timestamp] $Message" }
        'Warning' { Write-Host "##[warning][$timestamp] $Message" }
        'Error'   { Write-Host "##[error][$timestamp] $Message" }
    }
}

function Get-SqlConnection {
    try {
        # Build connection string
        if ($UseWindowsAuth) {
            $connString = "Server=$ServerInstance;Trusted_Connection=True;TrustServerCertificate=True;"
            Write-PipelineLog "Using Windows Authentication"
        } else {
            if ([string]::IsNullOrEmpty($SqlUsername) -or $null -eq $SqlPassword) {
                throw "SQL Authentication selected but credentials not provided"
            }

            # Convert SecureString to plain text for connection string (only in memory)
            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SqlPassword)
            $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

            $connString = "Server=$ServerInstance;User Id=$SqlUsername;Password=$plainPassword;TrustServerCertificate=True;"
            $plainPassword = $null # Clear the password from memory
            Write-PipelineLog "Using SQL Authentication"
        }
        return $connString
    }
    catch {
        throw "Failed to create SQL connection string: $($_.Exception.Message)"
    }
}

function Backup-Database {
    param (
        [string]$ConnectionString
    )
    try {
        # Generate backup filename if not provided
        if (-not $BackupFile) {
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $BackupFile = Join-Path $DataFilePath "$($DatabaseName)_$($BackupType)_$timestamp.bak"
        }

        # Ensure backup directory exists
        $backupDir = Split-Path $BackupFile -Parent
        if (-not (Test-Path $backupDir)) {
            Write-PipelineLog "Creating backup directory: $backupDir"
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }

        # Build backup command based on type
        $backupCmd = "BACKUP "
        switch ($BackupType) {
            'Full' { 
                $backupCmd += "DATABASE [$DatabaseName] TO DISK = N'$BackupFile'"
            }
            'Differential' { 
                $backupCmd += "DATABASE [$DatabaseName] TO DISK = N'$BackupFile' WITH DIFFERENTIAL"
            }
            'Log' { 
                $backupCmd += "LOG [$DatabaseName] TO DISK = N'$BackupFile'"
            }
        }

        # Add description if provided
        if ($Description) {
            $backupCmd += ", DESCRIPTION = N'$Description'"
        }

        $backupCmd += " WITH STATS = 10"

        Write-PipelineLog "Executing backup command..."
        Write-PipelineLog "Backup Type: $BackupType"
        Write-PipelineLog "Backup File: $BackupFile"
        
        Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $backupCmd -QueryTimeout $CommandTimeout -ErrorAction Stop
        Write-PipelineLog "Database backup completed successfully!"
        Write-PipelineLog "Backup file created at: $BackupFile"
    }
    catch {
        throw "Backup failed: $($_.Exception.Message)"
    }
}

function Restore-Database {
    param (
        [string]$ConnectionString
    )
    try {
        if (-not $BackupFile) {
            throw "Backup file path must be provided for restore operation"
        }

        # Verify backup file exists
        if (-not (Test-Path $BackupFile)) {
            throw "Backup file not found: $BackupFile"
        }

        # Set default paths if not provided
        if (-not $DataFilePath) {
            $DataFilePath = "$(Split-Path $BackupFile -Parent)\Data"
            Write-PipelineLog "Using default data file path: $DataFilePath" -Level Warning
        }
        
        if (-not $LogFilePath) {
            $LogFilePath = "$(Split-Path $BackupFile -Parent)\Log"
            Write-PipelineLog "Using default log file path: $LogFilePath" -Level Warning
        }

        # Ensure directories exist
        foreach ($path in @($DataFilePath, $LogFilePath)) {
            if (-not (Test-Path $path)) {
                Write-PipelineLog "Creating directory: $path"
                New-Item -ItemType Directory -Path $path -Force | Out-Null
            }
        }

        # Check if database exists
        $checkDbQuery = "SELECT name FROM sys.databases WHERE name = '$DatabaseName'"
        $existingDb = Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $checkDbQuery -ErrorAction Stop
        
        if ($existingDb -and -not $OverwriteExisting) {
            throw "Database '$DatabaseName' already exists and OverwriteExisting is not set"
        }
        elseif ($existingDb) {
            Write-PipelineLog "Database '$DatabaseName' exists. Dropping it as OverwriteExisting is set" -Level Warning
            $dropQuery = "ALTER DATABASE [$DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DatabaseName]"
            Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $dropQuery -ErrorAction Stop
        }

        # Get logical file names from backup
        Write-PipelineLog "Reading backup file information..."
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

        Write-PipelineLog "Executing restore command..."
        Write-PipelineLog "Restore query: $restoreQuery"
        
        Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $restoreQuery -QueryTimeout $CommandTimeout -ErrorAction Stop
        Write-PipelineLog "Database restore completed successfully!"
    }
    catch {
        throw "Restore failed: $($_.Exception.Message)"
    }
}

try {
    Write-PipelineLog "Starting database $Operation process..."
    Write-PipelineLog "Parameters received:"
    Write-PipelineLog "- Operation: $Operation"
    Write-PipelineLog "- Database Name: $DatabaseName"
    Write-PipelineLog "- Server Instance: $ServerInstance"

    $connectionString = Get-SqlConnection

    switch ($Operation) {
        'Backup' { 
            Backup-Database -ConnectionString $connectionString 
        }
        'Restore' { 
            Restore-Database -ConnectionString $connectionString 
        }
    }
    
    exit 0
}
catch {
    Write-PipelineLog "Error occurred during $Operation process:" -Level Error
    Write-PipelineLog $_.Exception.Message -Level Error
    Write-PipelineLog $_.Exception.StackTrace -Level Error
    exit 1
}
finally {
    # Ensure sensitive data is cleared from memory
    if ($connectionString) { $connectionString = $null }
    [System.GC]::Collect()
} 