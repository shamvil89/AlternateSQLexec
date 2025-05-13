[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$BackupFile,
    
    [Parameter(Mandatory=$true)]
    [string]$NewDatabaseName,
    
    [Parameter(Mandatory=$false)]
    [string]$DataFilePath = "E:\MSSQL\DBE\MSSQL16.MSSQLSERVER\MSSQL\DATA",
    
    [Parameter(Mandatory=$false)]
    [string]$LogFilePath = "E:\MSSQL\DBE\MSSQL16.MSSQLSERVER\MSSQL\DATA",
    
    [Parameter(Mandatory=$false)]
    [string]$ServerInstance = "DESKTOP-CIS3NI4",

    [Parameter(Mandatory=$false)]
    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty
)

function Write-Log {
    param($Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message"
}

try {
    # Import SQL Server module if not already loaded
    if (-not (Get-Module -Name SQLPS)) {
        Write-Log "Loading SQL Server PowerShell module..."
        Import-Module SQLPS -DisableNameChecking
    }

    Write-Log "Starting database restore process..."
    Write-Log "Backup File: $BackupFile"
    Write-Log "New Database Name: $NewDatabaseName"

    # Verify backup file exists
    if (-not (Test-Path $BackupFile)) {
        throw "Backup file not found: $BackupFile"
    }

    # Build connection string based on authentication type
    if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) {
        $connString = "Server=$ServerInstance;User Id=$($Credential.UserName);Password=$($Credential.GetNetworkCredential().Password);TrustServerCertificate=True;"
    } else {
        $connString = "Server=$ServerInstance;Trusted_Connection=True;TrustServerCertificate=True;"
    }

    # Get logical file names from backup
    Write-Log "Reading backup file information..."
    $query = @"
    RESTORE FILELISTONLY 
    FROM DISK = N'$BackupFile'
"@
    
    Write-Log "Connecting to SQL Server..."
    $fileList = Invoke-Sqlcmd -ConnectionString $connString -Query $query -ErrorAction Stop
    
    # Build the MOVE statements for each file
    $moveStatements = @()
    foreach ($file in $fileList) {
        $logicalName = $file.LogicalName
        $type = $file.Type
        
        # Determine target path based on file type
        $targetPath = if ($type -eq 'L') { $LogFilePath } else { $DataFilePath }
        
        # Construct new file name
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

    Write-Log "Executing restore command..."
    Write-Log "Restore query: $restoreQuery"
    
    Invoke-Sqlcmd -ConnectionString $connString -Query $restoreQuery -ErrorAction Stop
    
    Write-Log "Database restore completed successfully!"
}
catch {
    Write-Log "Error occurred during restore process:"
    Write-Log $_.Exception.Message
    Write-Log $_.Exception.StackTrace
    exit 1
} 