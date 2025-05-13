-- Create Database
IF NOT EXISTS (SELECT * FROM sys.databases WHERE name = 'SQLServerInventory')
BEGIN
    CREATE DATABASE SQLServerInventory;
END
GO

USE SQLServerInventory;
GO

-- Create Environments Table
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Environments')
BEGIN
    CREATE TABLE Environments (
        EnvironmentID INT IDENTITY(1,1) PRIMARY KEY,
        EnvironmentName NVARCHAR(50) NOT NULL,
        Description NVARCHAR(500),
        CreatedDate DATETIME DEFAULT GETDATE(),
        ModifiedDate DATETIME DEFAULT GETDATE(),
        CONSTRAINT UQ_Environment UNIQUE (EnvironmentName)
    );

    -- Insert default environments
    INSERT INTO Environments (EnvironmentName, Description)
    VALUES 
        ('PROD', 'Production Environment'),
        ('DEV', 'Development Environment'),
        ('QA', 'Quality Assurance Environment'),
        ('UAT', 'User Acceptance Testing Environment'),
        ('STG', 'Staging Environment');
END
GO

-- Create SQLInstances Table
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'SQLInstances')
BEGIN
    CREATE TABLE SQLInstances (
        InstanceID INT IDENTITY(1,1) PRIMARY KEY,
        ServerName NVARCHAR(255) NOT NULL,
        InstanceName NVARCHAR(255) NOT NULL,
        EnvironmentID INT FOREIGN KEY REFERENCES Environments(EnvironmentID),
        Version NVARCHAR(250),
        Edition sql_variant,
        ServiceAccount NVARCHAR(100),
        AuthenticationMode NVARCHAR(20),
        Port INT,
        InstallDate DATETIME,
        LastScanDate DATETIME DEFAULT GETDATE(),
        IsActive BIT DEFAULT 1,
        CONSTRAINT UQ_Instance UNIQUE (ServerName, InstanceName)
    );
END
GO

-- Create Databases Table
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Databases')
BEGIN
    CREATE TABLE Databases (
        DatabaseID INT IDENTITY(1,1) PRIMARY KEY,
        InstanceID INT FOREIGN KEY REFERENCES SQLInstances(InstanceID),
        DatabaseName NVARCHAR(255) NOT NULL,
        RecoveryModel NVARCHAR(20),
        CompatibilityLevel INT,
        CollationName NVARCHAR(100),
        CreationDate DATETIME,
        LastBackupDate DATETIME,
        LastFullBackupDate DATETIME,
        LastDiffBackupDate DATETIME,
        LastLogBackupDate DATETIME,
        SizeMB DECIMAL(18,2),
        SpaceUsedMB DECIMAL(18,2),
        Status NVARCHAR(50),
        IsActive BIT DEFAULT 1,
        LastScanDate DATETIME DEFAULT GETDATE(),
        CONSTRAINT UQ_Database UNIQUE (InstanceID, DatabaseName)
    );
END
GO

-- Create BackupHistory Table
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'BackupHistory')
BEGIN
    CREATE TABLE BackupHistory (
        BackupID INT IDENTITY(1,1) PRIMARY KEY,
        DatabaseID INT FOREIGN KEY REFERENCES Databases(DatabaseID),
        BackupType NVARCHAR(20), -- FULL, DIFFERENTIAL, LOG
        BackupStartDate DATETIME,
        BackupFinishDate DATETIME,
        BackupSizeMB DECIMAL(18,2),
        CompressedSizeMB DECIMAL(18,2),
        BackupLocation NVARCHAR(1000),
        IsCompressed BIT,
        IsEncrypted BIT,
        BackupSetName NVARCHAR(255),
        Status NVARCHAR(50),
        ErrorMessage NVARCHAR(MAX)
    );
END
GO

-- Create MaintenancePlans Table
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'MaintenancePlans')
BEGIN
    CREATE TABLE MaintenancePlans (
        PlanID INT IDENTITY(1,1) PRIMARY KEY,
        DatabaseID INT FOREIGN KEY REFERENCES Databases(DatabaseID),
        PlanName NVARCHAR(255),
        PlanType NVARCHAR(50), -- Backup, Index Maintenance, Integrity Check
        Frequency NVARCHAR(50),
        LastRunTime DATETIME,
        NextRunTime DATETIME,
        IsEnabled BIT DEFAULT 1,
        Description NVARCHAR(1000)
    );
END
GO

-- Create stored procedure to collect instance information
CREATE OR ALTER PROCEDURE sp_CollectInstanceInfo
    @ServerName NVARCHAR(255),
    @InstanceName NVARCHAR(255),
    @EnvironmentName NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SQL NVARCHAR(MAX);
    DECLARE @LinkedServer NVARCHAR(255) = QUOTENAME(@ServerName + CASE WHEN @InstanceName = 'MSSQLSERVER' THEN '' ELSE '\' + @InstanceName END);
    DECLARE @EnvironmentID INT;

    -- Get Environment ID
    SELECT @EnvironmentID = EnvironmentID 
    FROM Environments 
    WHERE EnvironmentName = @EnvironmentName;

    IF @EnvironmentID IS NULL
    BEGIN
        RAISERROR ('Invalid environment specified.', 16, 1);
        RETURN;
    END

    -- Update or insert instance information
    SET @SQL = N'
    INSERT INTO SQLInstances (
        ServerName, 
        InstanceName,
        EnvironmentID,
        Version, 
        Edition,
        ServiceAccount,
        AuthenticationMode,
        LastScanDate
    )
    SELECT 
        @ServerName,
        @InstanceName,
        @EnvironmentID,
        SERVERPROPERTY(''ProductVersion''),
        SERVERPROPERTY(''Edition''),
        service_account,
        CASE SERVERPROPERTY(''IsIntegratedSecurityOnly'') 
            WHEN 1 THEN ''Windows Authentication''
            ELSE ''Mixed Mode''
        END,
        GETDATE()
    FROM ' + @LinkedServer + '.master.sys.dm_server_services
    WHERE servicename LIKE ''SQL Server%''
    AND NOT EXISTS (
        SELECT 1 FROM SQLInstances 
        WHERE ServerName = @ServerName 
        AND InstanceName = @InstanceName
    );';

    EXEC sp_executesql @SQL, 
        N'@ServerName NVARCHAR(255), @InstanceName NVARCHAR(255), @EnvironmentID INT',
        @ServerName, @InstanceName, @EnvironmentID;
END;
GO

-- Create stored procedure to collect database information
CREATE OR ALTER PROCEDURE sp_CollectDatabaseInfo
    @ServerName NVARCHAR(255),
    @InstanceName NVARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SQL NVARCHAR(MAX);
    DECLARE @LinkedServer NVARCHAR(255) = QUOTENAME(@ServerName + CASE WHEN @InstanceName = 'MSSQLSERVER' THEN '' ELSE '\' + @InstanceName END);
    DECLARE @InstanceID INT;

    SELECT @InstanceID = InstanceID 
    FROM SQLInstances 
    WHERE ServerName = @ServerName 
    AND InstanceName = @InstanceName;

    SET @SQL = N'
    INSERT INTO Databases (
        InstanceID,
        DatabaseName,
        RecoveryModel,
        CompatibilityLevel,
        CollationName,
        CreationDate,
        SizeMB,
        SpaceUsedMB,
        Status,
        LastScanDate
    )
    SELECT 
        @InstanceID,
        name,
        recovery_model_desc,
        compatibility_level,
        collation_name,
        create_date,
        CAST(size * 8.0 / 1024 AS DECIMAL(18,2)),
        CAST(FILEPROPERTY(name, ''SpaceUsed'') * 8.0 / 1024 AS DECIMAL(18,2)),
        state_desc,
        GETDATE()
    FROM ' + @LinkedServer + '.master.sys.databases d
    WHERE NOT EXISTS (
        SELECT 1 FROM Databases 
        WHERE InstanceID = @InstanceID 
        AND DatabaseName = d.name
    );';

    EXEC sp_executesql @SQL, 
        N'@InstanceID INT',
        @InstanceID;
END;
GO

-- Create view for instance overview with environment information
CREATE OR ALTER VIEW vw_InstanceOverview
AS
SELECT 
    i.ServerName,
    i.InstanceName,
    e.EnvironmentName,
    i.Version,
    i.Edition,
    COUNT(d.DatabaseID) AS DatabaseCount,
    SUM(d.SizeMB) AS TotalSizeMB,
    MAX(d.LastBackupDate) AS LastBackupDate,
    i.LastScanDate
FROM SQLInstances i
LEFT JOIN Databases d ON i.InstanceID = d.InstanceID
INNER JOIN Environments e ON i.EnvironmentID = e.EnvironmentID
WHERE i.IsActive = 1
GROUP BY 
    i.ServerName,
    i.InstanceName,
    e.EnvironmentName,
    i.Version,
    i.Edition,
    i.LastScanDate;
GO

-- Create view for environment summary
CREATE OR ALTER VIEW vw_EnvironmentSummary
AS
SELECT 
    e.EnvironmentName,
    COUNT(DISTINCT i.InstanceID) AS InstanceCount,
    COUNT(DISTINCT d.DatabaseID) AS DatabaseCount,
    SUM(d.SizeMB) AS TotalSizeMB,
    MIN(d.LastBackupDate) AS OldestBackup,
    MAX(d.LastBackupDate) AS LatestBackup
FROM Environments e
LEFT JOIN SQLInstances i ON e.EnvironmentID = i.EnvironmentID
LEFT JOIN Databases d ON i.InstanceID = d.InstanceID
GROUP BY 
    e.EnvironmentName;
GO

-- Modify backup status view to include environment
CREATE OR ALTER VIEW vw_BackupStatus
AS
SELECT 
    i.ServerName,
    i.InstanceName,
    e.EnvironmentName,
    d.DatabaseName,
    d.RecoveryModel,
    d.LastFullBackupDate,
    d.LastDiffBackupDate,
    d.LastLogBackupDate,
    DATEDIFF(HOUR, d.LastFullBackupDate, GETDATE()) AS HoursSinceLastFullBackup,
    d.SizeMB,
    d.Status
FROM SQLInstances i
INNER JOIN Databases d ON i.InstanceID = d.InstanceID
INNER JOIN Environments e ON i.EnvironmentID = e.EnvironmentID
WHERE i.IsActive = 1 AND d.IsActive = 1;
GO

-- Insert sample data for local instance
INSERT INTO SQLInstances (ServerName, InstanceName, EnvironmentID, Version, Edition, AuthenticationMode)
SELECT 
    'localhost', 
    'MSSQLSERVER', 
    (SELECT EnvironmentID FROM Environments WHERE EnvironmentName = 'DEV'),
    @@VERSION, 
    SERVERPROPERTY('Edition'),
    CASE SERVERPROPERTY('IsIntegratedSecurityOnly') 
        WHEN 1 THEN 'Windows Authentication'
        ELSE 'Mixed Mode'
    END;

-- Example queries:
/*
-- View all SQL instances with their environments
SELECT * FROM vw_InstanceOverview;

-- View environment summary
SELECT * FROM vw_EnvironmentSummary;

-- View backup status by environment
SELECT * FROM vw_BackupStatus;

-- Collect instance information with environment
EXEC sp_CollectInstanceInfo 
    @ServerName = 'ServerName', 
    @InstanceName = 'MSSQLSERVER',
    @EnvironmentName = 'PROD';

-- List instances by environment
SELECT 
    e.EnvironmentName,
    i.ServerName,
    i.InstanceName,
    i.Version,
    i.Edition
FROM Environments e
INNER JOIN SQLInstances i ON e.EnvironmentID = i.EnvironmentID
ORDER BY e.EnvironmentName, i.ServerName;

-- Get database counts by environment
SELECT 
    e.EnvironmentName,
    COUNT(d.DatabaseID) AS DatabaseCount,
    SUM(d.SizeMB) AS TotalSizeMB
FROM Environments e
LEFT JOIN SQLInstances i ON e.EnvironmentID = i.EnvironmentID
LEFT JOIN Databases d ON i.InstanceID = d.InstanceID
GROUP BY e.EnvironmentName
ORDER BY e.EnvironmentName;
*/ 