[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$BackupFile,
    
    [Parameter(Mandatory=$true)]
    [string]$NewDatabaseName,
    
    [Parameter(Mandatory=$true)]
    [string]$ServerInstance,
    
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
    [switch]$OverwriteExisting = $false
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

try {
    Write-PipelineLog "Starting database restore process..."
    Write-PipelineLog "Parameters received:"
    Write-PipelineLog "- Backup File: $BackupFile"
    Write-PipelineLog "- New Database Name: $NewDatabaseName"
    Write-PipelineLog "- Server Instance: $ServerInstance"

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
    if (-not (Test-Path $DataFilePath)) {
        Write-PipelineLog "Creating data directory: $DataFilePath"
        New-Item -ItemType Directory -Path $DataFilePath -Force | Out-Null
    }
    
    if (-not (Test-Path $LogFilePath)) {
        Write-PipelineLog "Creating log directory: $LogFilePath"
        New-Item -ItemType Directory -Path $LogFilePath -Force | Out-Null
    }

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

    # Check if database exists and handle accordingly
    $checkDbQuery = "SELECT name FROM sys.databases WHERE name = '$NewDatabaseName'"
    $existingDb = Invoke-Sqlcmd -ConnectionString $connString -Query $checkDbQuery -ErrorAction Stop
    
    if ($existingDb -and -not $OverwriteExisting) {
        throw "Database '$NewDatabaseName' already exists and OverwriteExisting is not set"
    }
    elseif ($existingDb) {
        Write-PipelineLog "Database '$NewDatabaseName' exists. Dropping it as OverwriteExisting is set" -Level Warning
        $dropQuery = "ALTER DATABASE [$NewDatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$NewDatabaseName]"
        Invoke-Sqlcmd -ConnectionString $connString -Query $dropQuery -ErrorAction Stop
    }

    # Get logical file names from backup
    Write-PipelineLog "Reading backup file information..."
    $fileListQuery = "RESTORE FILELISTONLY FROM DISK = N'$BackupFile'"
    $fileList = Invoke-Sqlcmd -ConnectionString $connString -Query $fileListQuery -ErrorAction Stop
    
    # Build the MOVE statements for each file
    $moveStatements = @()
    foreach ($file in $fileList) {
        $logicalName = $file.LogicalName
        $type = $file.Type
        
        $targetPath = if ($type -eq 'L') { $LogFilePath } else { $DataFilePath }
        $newFileName = if ($type -eq 'L') {
            "${NewDatabaseName}_log.ldf"
        } else {
            "${NewDatabaseName}.mdf"
        }
        
        $fullPath = Join-Path $targetPath $newFileName
        $moveStatements += "MOVE N'$logicalName' TO N'$fullPath'"
    }

    # Build and execute the restore command
    $restoreQuery = @"
    RESTORE DATABASE [$NewDatabaseName] 
    FROM DISK = N'$BackupFile' 
    WITH FILE = 1,
    $(($moveStatements) -join ",`n    "),
    STATS = 10
"@

    Write-PipelineLog "Executing restore command..."
    Write-PipelineLog "Restore query: $restoreQuery"
    
    Invoke-Sqlcmd -ConnectionString $connString -Query $restoreQuery -QueryTimeout $CommandTimeout -ErrorAction Stop
    
    Write-PipelineLog "Database restore completed successfully!"
    
    # Set exit code for pipeline
    exit 0
}
catch {
    Write-PipelineLog "Error occurred during restore process:" -Level Error
    Write-PipelineLog $_.Exception.Message -Level Error
    Write-PipelineLog $_.Exception.StackTrace -Level Error
    
    # Set error exit code for pipeline
    exit 1
}
finally {
    # Ensure sensitive data is cleared from memory
    if ($connString) { $connString = $null }
    [System.GC]::Collect()
} 