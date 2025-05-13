# Import required modules
Import-Module SqlServer

# Add SMO assemblies
Add-Type -AssemblyName "Microsoft.SqlServer.Smo, Version=16.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91"
Add-Type -AssemblyName "Microsoft.SqlServer.SmoExtended, Version=16.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91"
Add-Type -AssemblyName "Microsoft.SqlServer.ConnectionInfo, Version=16.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91"
Add-Type -AssemblyName "Microsoft.SqlServer.Management.Sdk.Sfc, Version=16.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91"

# Configuration settings
$script:config = @{
    InventoryServer = "" # Will be set during initialization
    InventoryDatabase = "SQLServerInventory"
}

# Function to initialize configuration
function Initialize-Configuration {
    Write-Host "SQL Server Inventory Configuration"
    Write-Host "--------------------------------"
    $script:config.InventoryServer = Read-Host "Enter the SQL Server instance where inventory database is hosted (e.g., ServerName\InstanceName)"
    
    # Test connection to inventory database
    try {
        $testParams = @{
            ServerInstance = $script:config.InventoryServer
            Database = $script:config.InventoryDatabase
            Query = "SELECT @@VERSION AS Version"
            ErrorAction = "Stop"
            TrustServerCertificate = $true
        }
        $result = Invoke-Sqlcmd @testParams
        Write-Host "Successfully connected to inventory database on $($script:config.InventoryServer)" -ForegroundColor Green
        Write-Host "SQL Server Version: $($result.Version)"
    }
    catch {
        Write-Error "Failed to connect to inventory database: $_"
        exit 1
    }
}

# Function to find an available port
function Find-AvailablePort {
    param (
        [int]$StartPort = 8080,
        [int]$EndPort = 8090
    )
    
    for ($port = $StartPort; $port -le $EndPort; $port++) {
        $listener = $null
        try {
            $listener = New-Object System.Net.HttpListener
            $listener.Prefixes.Add("http://localhost:$port/")
            $listener.Start()
            $listener.Stop()
            return $port
        }
        catch {
            # Port is in use, continue to next port
            continue
        }
        finally {
            if ($listener) {
                $listener.Close()
            }
        }
    }
    throw "No available ports found between $StartPort and $EndPort"
}

# Function to cleanup existing listeners
function Stop-ExistingListeners {
    try {
        $netstat = netstat -aon | Select-String "LISTENING"
        foreach ($line in $netstat) {
            if ($line -match ":8080\s+.*\s+(\d+)$") {
                $processId = $matches[1]
                try {
                    Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
                    Write-Host "Stopped process with PID: $processId that was using port 8080"
                    Start-Sleep -Seconds 1
                }
                catch {
                    Write-Warning "Could not stop process with PID: $processId"
                }
            }
        }
    }
    catch {
        Write-Warning "Error cleaning up existing listeners: $_"
    }
}

# Main server setup
try {
    # Initialize configuration
    Initialize-Configuration

    # Try to clean up existing listeners
    Stop-ExistingListeners

    # Find available port
    $port = Find-AvailablePort
    $http = [System.Net.HttpListener]::new()
    $http.Prefixes.Add("http://localhost:$port/")
    
    # Try to start the server
    try {
        $http.Start()
        Write-Host "Server started at http://localhost:$port/"
    }
    catch {
        Write-Error "Failed to start server: $_"
        exit 1
    }

    function Send-Response($response, $statusCode, $data) {
        try {
            Write-Host "Preparing response with status code: $statusCode"
            $response.StatusCode = $statusCode
            $response.ContentType = "application/json"
            
            # Convert data to JSON with proper depth
            $jsonResponse = $data | ConvertTo-Json -Depth 10 -Compress
            Write-Host "JSON response: $jsonResponse"
            
            $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonResponse)
            $response.ContentLength64 = $jsonBytes.Length
            
            Write-Host "Writing response bytes: $($jsonBytes.Length) bytes"
            $response.OutputStream.Write($jsonBytes, 0, $jsonBytes.Length)
            Write-Host "Response written successfully"
        }
        catch {
            Write-Warning "Error sending response: $_"
            Write-Warning "Error details: $($_.Exception)"
            try {
                if (-not $response.ContentLength64) {
                    $errorJson = @{ error = "Internal server error: $($_.Exception.Message)" } | ConvertTo-Json
                    $errorBytes = [System.Text.Encoding]::UTF8.GetBytes($errorJson)
                    $response.ContentLength64 = $errorBytes.Length
                    $response.OutputStream.Write($errorBytes, 0, $errorBytes.Length)
                }
            }
            catch {
                Write-Warning "Failed to send error response: $_"
            }
        }
        finally {
            if ($response) {
                try {
                    $response.Close()
                    Write-Host "Response closed"
                }
                catch {
                    Write-Warning "Error closing response: $_"
                }
            }
        }
    }

    function Get-InstanceEnvironment($serverName) {
        try {
            # Extract instance name if provided
            $instanceParts = $serverName -split '\\'
            $serverName = $instanceParts[0]
            $instanceName = if ($instanceParts.Count -gt 1) { $instanceParts[1] } else { $serverName }

            # Query the inventory database using the view
            $query = @"
            SELECT TOP 1 EnvironmentName
            FROM $($script:config.InventoryDatabase).dbo.vw_InstanceOverview
            WHERE ServerName = '$instanceName'
"@
            # Add connection parameters to trust server certificate
            $connectionParams = @{
                ServerInstance = $script:config.InventoryServer
                Query = $query
                ErrorAction = "Stop"
                TrustServerCertificate = $true
            }
            
            $result = Invoke-Sqlcmd @connectionParams
            
            if ($result) {
                return @{
                    environment = $result.EnvironmentName
                }
            }
            
            return @{
                error = "Server not found in inventory"
            }
        }
        catch {
            return @{
                error = $_.Exception.Message
            }
        }
    }

    # Function to invoke SQL queries
    function Invoke-SqlQuery($serverName, $query, $action) {
        try {
            # First check if this is a production instance
            $envInfo = Get-InstanceEnvironment $serverName
            if ($envInfo.environment -eq 'PROD') {
                return @{
                    error = "Operation not allowed on Production instance"
                }
            }

            Write-Host "Executing query on $serverName"

            # Extract database name from the query if it exists
            $databaseMatch = [regex]::Match($query, "FROM\s+([^.\s]+)\.dbo\.")
            $databaseName = if ($databaseMatch.Success) { $databaseMatch.Groups[1].Value } else { "master" }
            Write-Host "Using database: $databaseName"

            # Create connection with the correct database
            $connection = New-Object System.Data.SqlClient.SqlConnection
            $connection.ConnectionString = "Server=$serverName;Database=$databaseName;Trusted_Connection=True;TrustServerCertificate=True"
            
            try {
                $connection.Open()
            }
            catch {
                return @{
                    error = "Failed to connect to database '$databaseName': $($_.Exception.Message)"
                }
            }

            Write-Host "Connected successfully to $serverName, database: $databaseName"

            switch ($action) {
                "parse" {
                    try {
                        # Enable PARSEONLY
                        $command = New-Object System.Data.SqlClient.SqlCommand("SET PARSEONLY ON", $connection)
                        $null = $command.ExecuteNonQuery()
                        $command.Dispose()

                        # Parse the query
                        $command = New-Object System.Data.SqlClient.SqlCommand($query, $connection)
                        $null = $command.ExecuteNonQuery()
                        $command.Dispose()

                        # Disable PARSEONLY
                        $command = New-Object System.Data.SqlClient.SqlCommand("SET PARSEONLY OFF", $connection)
                        $null = $command.ExecuteNonQuery()

                        return @{
                            message = "Query syntax is valid"
                        }
                    }
                    catch {
                        Write-Host "Error parsing query: $_"
                        return @{
                            error = $_.Exception.Message
                        }
                    }
                    finally {
                        if ($command) { $command.Dispose() }
                    }
                }
                "execute" {
                    try {
                        # Check if this is a RESTORE command
                        if ($query -match '^\s*RESTORE\s+') {
                            Write-Host "Executing RESTORE command..."
                            
                            # Execute the restore command directly
                            $command = New-Object System.Data.SqlClient.SqlCommand($query, $connection)
                            $command.CommandTimeout = 300  # Longer timeout for restore operations
                            
                            try {
                                $null = $command.ExecuteNonQuery()
                                return @{
                                    message = "Restore command executed successfully"
                                    results = @()
                                }
                            }
                            catch {
                                Write-Host "Error executing restore command: $_"
                                return @{
                                    error = $_.Exception.Message
                                    message = "Error: $($_.Exception.Message)"
                                }
                            }
                        }
                        
                        # For non-restore queries, proceed with normal execution
                        # Extract table name from query for validation
                        $tableMatch = [regex]::Match($query, "FROM\s+([^\s;]+)")
                        if ($tableMatch.Success) {
                            $tableName = $tableMatch.Groups[1].Value
                            Write-Host "Validating existence of table: $tableName"
                            
                            # Check if table exists before executing the query
                            $checkCmd = New-Object System.Data.SqlClient.SqlCommand(@"
                                IF EXISTS (
                                    SELECT 1 
                                    FROM sys.objects 
                                    WHERE object_id = OBJECT_ID(@tableName) 
                                    AND type in (N'U', N'V')
                                )
                                SELECT 1
                                ELSE
                                SELECT 0
"@, $connection)
                            $checkCmd.Parameters.AddWithValue("@tableName", $tableName)
                            
                            $tableExists = [int]$checkCmd.ExecuteScalar() -eq 1
                            
                            if (-not $tableExists) {
                                return @{
                                    error = "Table or view '$tableName' does not exist in database '$databaseName'. Please verify the object name and database context."
                                    message = "Error: Table or view '$tableName' does not exist in database '$databaseName'"
                                }
                            }
                        }

                        # Create SQL connection to capture print messages
                        $printMessages = New-Object System.Collections.ArrayList
                        
                        # Add message handler
                        $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] {
                            param($sqlSender, $sqlEventArgs)
                            foreach ($error in $sqlEventArgs.Errors) {
                                $null = $printMessages.Add($error.Message)
                                # If this is an error message (not just info), capture it
                                if ($error.Class -gt 10) {  # Class > 10 indicates an error
                                    Write-Host "SQL Error detected: $($error.Message)"
                                    throw [System.Data.SqlClient.SqlException]::new($error.Message)
                                }
                            }
                        }
                        $connection.add_InfoMessage($handler)
                        $connection.FireInfoMessageEventOnUserErrors = $true
                        
                        Write-Host "Executing query: $query"
                        
                        # Execute the query
                        $command = New-Object System.Data.SqlClient.SqlCommand($query, $connection)
                        $command.CommandTimeout = 30
                        
                        try {
                            $reader = $command.ExecuteReader()
                            
                            # Convert results to array of hashtables
                            $formattedResults = @()
                            
                            # Get column names
                            $columns = @()
                            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                                $columns += $reader.GetName($i)
                            }
                            
                            Write-Host "Query columns: $($columns -join ', ')"
                            
                            if ($reader.HasRows) {
                                while ($reader.Read()) {
                                    $row = @{}
                                    for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                                        $value = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) }
                                        $row[$columns[$i]] = $value
                                    }
                                    $formattedResults += $row
                                }
                                Write-Host "Query returned $($formattedResults.Count) rows"
                            } else {
                                Write-Host "Query returned no rows"
                            }
                            
                            $reader.Close()
                            
                            # Only return success message if there were no error messages
                            if ($printMessages.Count -eq 0) {
                                return @{
                                    results = $formattedResults
                                    messages = $printMessages
                                    message = if ($formattedResults.Count -eq 0) { 
                                        "Query executed successfully but returned no results" 
                                    } else { 
                                        "Query executed successfully. Returned $($formattedResults.Count) rows." 
                                    }
                                }
                            } else {
                                # If we have error messages, treat them as errors
                                return @{
                                    error = $printMessages[0]  # Use first error message as main error
                                    message = "Error: $($printMessages[0])"  # Format for display
                                    messages = $printMessages  # Keep all messages for reference
                                    results = @()  # Empty results since there was an error
                                }
                            }
                        }
                        catch {
                            Write-Host "Error executing query: $_"
                            # Check for specific error numbers
                            if ($_.Exception.Message -match "Invalid object name") {
                                return @{
                                    error = "Table or view does not exist. Please check the object name and database context."
                                    message = "Error: Table or view does not exist"
                                    messages = @($_.Exception.Message)
                                    results = @()
                                }
                            }
                            # Handle other SQL errors
                            if ($_.Exception.GetType().Name -eq 'SqlException') {
                                $sqlEx = $_.Exception
                                return @{
                                    error = "SQL Error $($sqlEx.Number): $($sqlEx.Message)"
                                    message = "Error: SQL Error $($sqlEx.Number): $($sqlEx.Message)"
                                    messages = @($sqlEx.Message)
                                    results = @()
                                }
                            }
                            throw
                        }
                    }
                    catch {
                        Write-Host "Error in SQL execution: $_"
                        return @{
                            error = $_.Exception.Message
                            message = "Error: $($_.Exception.Message)"
                        }
                    }
                    finally {
                        if ($reader) { $reader.Dispose() }
                        if ($command) { $command.Dispose() }
                        if ($checkCmd) { $checkCmd.Dispose() }
                    }
                }
                "plan" {
                    try {
                        Write-Host "Getting estimated execution plan..."
                        
                        # First, check if the query is valid by parsing it
                        $parseCmd = New-Object System.Data.SqlClient.SqlCommand("SET PARSEONLY ON", $connection)
                        $parseCmd.ExecuteNonQuery()
                        
                        $testCmd = New-Object System.Data.SqlClient.SqlCommand($query, $connection)
                        $testCmd.ExecuteNonQuery()
                        
                        $parseCmd = New-Object System.Data.SqlClient.SqlCommand("SET PARSEONLY OFF", $connection)
                        $parseCmd.ExecuteNonQuery()

                        # Now get the execution plan using SET SHOWPLAN_XML
                        Write-Host "Query is valid, getting execution plan..."
                        
                        # Enable SHOWPLAN_XML
                        $cmd = New-Object System.Data.SqlClient.SqlCommand("SET SHOWPLAN_XML ON", $connection)
                        $cmd.ExecuteNonQuery()
                        
                        # Execute the query to get the plan
                        $cmd = New-Object System.Data.SqlClient.SqlCommand($query, $connection)
                        $reader = $cmd.ExecuteReader()
                        
                        # Get the execution plan XML
                        $planXml = ""
                        if ($reader.Read()) {
                            $planXml = $reader.GetString(0)
                        }
                        $reader.Close()
                        
                        # Disable SHOWPLAN_XML
                        $cmd = New-Object System.Data.SqlClient.SqlCommand("SET SHOWPLAN_XML OFF", $connection)
                        $cmd.ExecuteNonQuery()
                        
                        if ($planXml) {
                            Write-Host "Raw plan XML length: $($planXml.Length)"
                            
                            # Validate the XML
                            try {
                                [xml]$xmlDoc = $planXml
                                
                                # Get the XML namespace
                                $ns = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
                                $ns.AddNamespace("sqp", "http://schemas.microsoft.com/sqlserver/2004/07/showplan")
                                
                                # Check root element with namespace
                                $hasShowPlanXML = $xmlDoc.DocumentElement.LocalName -eq 'ShowPlanXML'
                                
                                # Check for statement elements using namespace
                                $stmtNodes = $xmlDoc.SelectNodes("//sqp:StmtSimple | //sqp:StmtCompound", $ns)
                                $hasStmtElement = $null -ne $stmtNodes -and $stmtNodes.Count -gt 0
                                
                                if ($hasShowPlanXML -and $hasStmtElement) {
                                    Write-Host "Valid execution plan found"
                                    return @{
                                        plan = $planXml
                                        message = "Execution plan generated successfully"
                                    }
                                } else {
                                    return @{
                                        error = "Generated XML is not a valid execution plan - missing required elements"
                                    }
                                }
                            }
                            catch {
                                Write-Host "XML parsing error: $_"
                                return @{
                                    error = "Invalid XML format in execution plan: $($_.Exception.Message)"
                                }
                            }
                        } else {
                            return @{
                                error = "No execution plan was generated"
                            }
                        }
                    }
                    catch {
                        Write-Host "Error getting execution plan: $_"
                        return @{
                            error = "Failed to generate execution plan: $($_.Exception.Message)"
                        }
                    }
                    finally {
                        if ($reader) { $reader.Dispose() }
                        if ($cmd) { $cmd.Dispose() }
                    }
                }
            }
        }
        catch {
            Write-Host "Error executing query: $_"
            return @{
                error = $_.Exception.Message
            }
        }
        finally {
            if ($connection -and $connection.State -eq 'Open') {
                try {
                    $connection.Close()
                    $connection.Dispose()
                }
                catch {
                    Write-Host "Warning: Error closing connection: $_"
                }
            }
        }
    }

    function Send-StaticFile($path, $response) {
        $extension = [System.IO.Path]::GetExtension($path)
        $contentType = switch ($extension) {
            ".html" { "text/html" }
            ".css"  { "text/css" }
            ".js"   { "application/javascript" }
            default { "text/plain" }
        }
        
        try {
            $content = Get-Content $path -Raw
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($content)
            $response.ContentType = $contentType
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        catch {
            Send-Response $response 404 @{ error = "File not found" }
        }
        finally {
            if ($response) {
                $response.Close()
            }
        }
    }

    function Get-DatabaseObjects($serverName, $objectType, $context) {
        try {
            Write-Host "Attempting to connect to server: $serverName for $objectType"
            if ($context) {
                Write-Host "Context: $($context | ConvertTo-Json)"
            }
            
            # Create SQL Server connection with proper settings
            $server = New-Object Microsoft.SqlServer.Management.Smo.Server($serverName)
            $server.ConnectionContext.ConnectTimeout = 30
            $server.ConnectionContext.StatementTimeout = 60
            $server.ConnectionContext.ApplicationName = "SQL Query Executor"
            $server.ConnectionContext.TrustServerCertificate = $true
            
            # Test connection
            $null = $server.ConnectionContext.Connect()
            
            # Get database name from context or use current
            $dbName = if ($context.database) { $context.database } else { $server.ConnectionContext.CurrentDatabase }
            Write-Host "Using database: $dbName"
            
            # Initialize results array
            $objects = @()
            
            switch ($objectType) {
                "databases" {
                    # Get user databases
                    $objects = $server.Databases |
                        Where-Object { -not $_.IsSystemObject } |
                        Select-Object @{N='name';E={$_.Name}},
                                    @{N='type';E={'database'}},
                                    @{N='isCurrentDb';E={$_.Name -eq $dbName}}
                }
                "tables" {
                    # Get user tables from specified database
                    $objects = $server.Databases[$dbName].Tables | 
                        Where-Object { -not $_.IsSystemObject } |
                        Sort-Object CreateDate -Descending |
                        Select-Object -First 100 |
                        Select-Object @{N='name';E={$_.Name}}, 
                                    @{N='type';E={'table'}}, 
                                    @{N='schema';E={$_.Schema}},
                                    @{N='database';E={$dbName}}
                }
                "views" {
                    # Get views from specified database
                    $objects = $server.Databases[$dbName].Views |
                        Where-Object { -not $_.IsSystemObject } |
                        Sort-Object CreateDate -Descending |
                        Select-Object -First 100 |
                        Select-Object @{N='name';E={$_.Name}}, 
                                    @{N='type';E={'view'}}, 
                                    @{N='schema';E={$_.Schema}},
                                    @{N='database';E={$dbName}}
                }
                "columns" {
                    if ($context.table) {
                        # Get columns for specific table
                        Write-Host "Fetching columns for table: $($context.table)"
                        $table = $server.Databases[$dbName].Tables[$context.table]
                        if ($table) {
                            $objects = $table.Columns |
                                Select-Object @{N='name';E={$_.Name}}, 
                                            @{N='type';E={'column'}}, 
                                            @{N='dataType';E={$_.DataType.Name}},
                                            @{N='table';E={$table.Name}},
                                            @{N='schema';E={$table.Schema}},
                                            @{N='database';E={$dbName}}
                        }
                    } else {
                        # Get columns from most commonly used tables
                        $objects = $server.Databases[$dbName].Tables |
                            Where-Object { -not $_.IsSystemObject } |
                            Sort-Object CreateDate -Descending |
                            Select-Object -First 20 |
                            ForEach-Object {
                                $tableName = $_.Name
                                $schemaName = $_.Schema
                                $_.Columns | Select-Object @{N='name';E={$_.Name}}, 
                                                         @{N='type';E={'column'}}, 
                                                         @{N='dataType';E={$_.DataType.Name}},
                                                         @{N='table';E={$tableName}},
                                                         @{N='schema';E={$schemaName}},
                                                         @{N='database';E={$dbName}}
                            }
                    }
                }
                default {
                    throw "Invalid object type specified: $objectType"
                }
            }
            
            Write-Host "Retrieved $($objects.Count) $objectType"
            return @{
                objects = @($objects) # Ensure it's always an array
            }
        }
        catch {
            Write-Warning "Error in Get-DatabaseObjects: $_"
            Write-Warning "Stack trace: $($_.ScriptStackTrace)"
            return @{
                error = "Failed to get database objects: $($_.Exception.Message)"
            }
        }
        finally {
            if ($server -and $server.ConnectionContext.IsOpen) {
                $server.ConnectionContext.Disconnect()
            }
        }
    }

    # Main request handling loop
    while ($http.IsListening) {
        try {
            $context = $http.GetContext()
            $request = $context.Request
            $response = $context.Response
            
            Write-Host "Received $($request.HttpMethod) request for $($request.RawUrl)"
            
            # Read request body for POST requests
            $body = $null
            if ($request.HasEntityBody) {
                $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                $body = $reader.ReadToEnd()
                $data = $body | ConvertFrom-Json
            }
            
            switch ($request.HttpMethod) {
                "GET" {
                    $path = $request.Url.LocalPath
                    if ($path -eq "/" -or $path -eq "") {
                        $path = "/index.html"
                    }
                    
                    $filePath = Join-Path $PSScriptRoot $path.TrimStart("/")
                    Write-Host "Serving static file: $filePath"
                    Send-StaticFile $filePath $response
                    break
                }
                
                "POST" {
                    switch ($request.Url.LocalPath) {
                        "/api/database-objects" {
                            Write-Host "Received request to /api/database-objects"
                            $result = Get-DatabaseObjects -serverName $data.serverName -objectType $data.objectType -context $data.context
                            Send-Response -response $response -statusCode 200 -data $result
                        }
                        "/api/execute" {
                            Write-Host "Received request to /api/execute"
                            $result = Invoke-SqlQuery $data.serverName $data.query $data.action
                            Write-Host "Result to be sent: $($result | ConvertTo-Json -Depth 10)"
                            Send-Response $response 200 $result
                        }
                        "/api/validate-environment" {
                            Write-Host "Received request to /api/validate-environment"
                            $result = Get-InstanceEnvironment $data.serverName
                            Send-Response $response 200 $result
                        }
                        default {
                            Send-Response $response 404 @{ error = "Endpoint not found" }
                        }
                    }
                    break
                }
                
                default {
                    Send-Response $response 405 @{ error = "Method not allowed" }
                }
            }
        }
        catch {
            Write-Warning "Error processing request: $_"
            Send-Response $response 500 @{ error = $_.Exception.Message }
        }
    }
}
catch {
    Write-Error "Server error: $_"
}
finally {
    if ($http) {
        try {
            $http.Stop()
            $http.Close()
            Write-Host "Server stopped successfully"
        }
        catch {
            Write-Warning "Error stopping server: $_"
        }
    }
} 