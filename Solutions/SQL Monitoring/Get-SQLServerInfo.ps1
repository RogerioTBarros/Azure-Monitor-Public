<#
.SYNOPSIS
    Collects SQL Server database and instance information and writes to Windows Event Log.

.DESCRIPTION
    This script gathers SQL Server metrics including:
    - Database uptime
    - SQL Server Instance uptime
    - Database last backup status
    - Database last backup time
    
    The output is written to Windows Event Log in JSON format for Azure Monitor DCR ingestion.

.PARAMETER SqlInstance
    The SQL Server instance name. Default is localhost.

.PARAMETER EventLogName
    The Windows Event Log name to write to. Default is "Application".

.PARAMETER EventSource
    The Event Source name. Default is "SQLServerMonitor".

.PARAMETER UseSqlAuthentication
    Use SQL Server authentication instead of Windows authentication.

.PARAMETER SqlUsername
    The SQL Server username (used with -UseSqlAuthentication).

.PARAMETER CredentialPath
    Path to the encrypted credential file created by Save-SqlCredential.

.EXAMPLE
    .\Get-SQLServerInfo.ps1 -SqlInstance "localhost"
    
.EXAMPLE
    .\Get-SQLServerInfo.ps1 -SqlInstance "YOURSERVER\SQLINSTANCE" -EventLogName "SQLMonitor"

.EXAMPLE
    # First, save credentials (run once interactively as the scheduled task user)
    . .\Get-SQLServerInfo.ps1
    Save-SqlCredential -Path "C:\Scripts\sqlcred.xml" -Username "SQLMonitorReader"
    
    # Then run with SQL Authentication
    .\Get-SQLServerInfo.ps1 -SqlInstance "localhost" -UseSqlAuthentication -CredentialPath "C:\Scripts\sqlcred.xml"

.NOTES
    Author: Azure Monitor Assets
    Version: 1.1
    Date: 2024-12-09
    
    Prerequisites:
    - SQL Server PowerShell module (SqlServer) or use .NET SQL Client
    - Appropriate SQL Server permissions to query system views
    - Run as administrator to create event source if needed
    
    For non-domain joined servers with mixed authentication:
    1. Create a SQL login with VIEW SERVER STATE and SELECT on msdb.dbo.backupset
    2. Save credentials using Save-SqlCredential (run as the scheduled task user)
    3. Use -UseSqlAuthentication -CredentialPath parameters
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$SqlInstance = "localhost",

    [Parameter(Mandatory = $false)]
    [string]$EventLogName = "Application",

    [Parameter(Mandatory = $false)]
    [string]$EventSource = "SQLServerMonitor",

    [Parameter(Mandatory = $false)]
    [int]$EventId = 1000,

    [Parameter(Mandatory = $false)]
    [switch]$UseSqlAuthentication,

    [Parameter(Mandatory = $false)]
    [string]$SqlUsername,

    [Parameter(Mandatory = $false)]
    [string]$CredentialPath
)

#region Functions

function Initialize-EventSource {
    <#
    .SYNOPSIS
        Creates the Event Source if it doesn't exist
    #>
    param (
        [string]$LogName,
        [string]$Source
    )
    
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) {
            [System.Diagnostics.EventLog]::CreateEventSource($Source, $LogName)
            Write-Verbose "Created Event Source: $Source in Log: $LogName"
            # Wait a moment for the source to be available
            Start-Sleep -Seconds 2
        }
    }
    catch {
        Write-Warning "Could not create Event Source. Run as Administrator or create manually. Error: $_"
    }
}

function Get-SqlCredential {
    <#
    .SYNOPSIS
        Retrieves SQL credentials from encrypted file or prompts for them
    #>
    param (
        [string]$CredentialPath,
        [string]$Username
    )
    
    if ($CredentialPath -and (Test-Path $CredentialPath)) {
        try {
            $credential = Import-Clixml -Path $CredentialPath
            Write-Verbose "Loaded credentials from: $CredentialPath"
            return $credential
        }
        catch {
            Write-Warning "Failed to load credentials from file: $_"
        }
    }
    
    if ($Username) {
        # For non-interactive use, we need the credential file
        throw "SQL Authentication requires a credential file. Use Save-SqlCredential to create one."
    }
    
    return $null
}

function Save-SqlCredential {
    <#
    .SYNOPSIS
        Saves SQL credentials to an encrypted file (run interactively once)
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Username
    )
    
    $credential = Get-Credential -UserName $Username -Message "Enter SQL Server password for $Username"
    $credential | Export-Clixml -Path $Path
    Write-Host "Credentials saved to: $Path" -ForegroundColor Green
    Write-Host "NOTE: This file can only be decrypted by the same user on this machine." -ForegroundColor Yellow
}

function Get-SqlServerInstanceUptime {
    <#
    .SYNOPSIS
        Gets the SQL Server instance uptime
    #>
    param (
        [System.Data.SqlClient.SqlConnection]$Connection
    )
    
    $query = @"
SELECT 
    sqlserver_start_time,
    DATEDIFF(SECOND, sqlserver_start_time, GETDATE()) AS uptime_seconds,
    DATEDIFF(MINUTE, sqlserver_start_time, GETDATE()) AS uptime_minutes,
    DATEDIFF(HOUR, sqlserver_start_time, GETDATE()) AS uptime_hours,
    DATEDIFF(DAY, sqlserver_start_time, GETDATE()) AS uptime_days
FROM sys.dm_os_sys_info
"@

    try {
        $command = New-Object System.Data.SqlClient.SqlCommand($query, $Connection)
        $command.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($command)
        $dataTable = New-Object System.Data.DataTable
        $rowCount = $adapter.Fill($dataTable)
        Write-Verbose "Instance uptime query filled $rowCount rows"
        # Use Write-Output with -NoEnumerate to prevent PowerShell from unwrapping single-row DataTables
        Write-Output -NoEnumerate $dataTable
    }
    catch {
        Write-Warning "Failed to query sys.dm_os_sys_info: $($_.Exception.Message)"
        Write-Warning "This requires VIEW SERVER STATE permission."
        throw
    }
}

function Get-DatabaseUptime {
    <#
    .SYNOPSIS
        Gets database uptime (time since database came online)
    #>
    param (
        [System.Data.SqlClient.SqlConnection]$Connection
    )
    
    $query = @"
SELECT 
    d.name AS database_name,
    d.state_desc AS database_state,
    d.create_date,
    CASE 
        WHEN d.state = 0 THEN 
            COALESCE(
                (SELECT MAX(login_time) 
                 FROM sys.dm_exec_sessions 
                 WHERE database_id = d.database_id),
                (SELECT sqlserver_start_time FROM sys.dm_os_sys_info)
            )
        ELSE NULL 
    END AS online_since,
    CASE 
        WHEN d.state = 0 THEN 
            DATEDIFF(SECOND, 
                COALESCE(
                    (SELECT sqlserver_start_time FROM sys.dm_os_sys_info),
                    d.create_date
                ), 
                GETDATE())
        ELSE NULL 
    END AS uptime_seconds
FROM sys.databases d
WHERE d.database_id > 4  -- Exclude system databases, remove this line to include them
ORDER BY d.name
"@

    $command = New-Object System.Data.SqlClient.SqlCommand($query, $Connection)
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($command)
    $dataTable = New-Object System.Data.DataTable
    $adapter.Fill($dataTable) | Out-Null
    
    # Use Write-Output with -NoEnumerate to prevent PowerShell from unwrapping single-row DataTables
    Write-Output -NoEnumerate $dataTable
}

function Get-DatabaseBackupStatus {
    <#
    .SYNOPSIS
        Gets the last backup status for all databases
    #>
    param (
        [System.Data.SqlClient.SqlConnection]$Connection
    )
    
    $query = @"
SELECT 
    d.name AS database_name,
    d.recovery_model_desc AS recovery_model,
    d.state_desc AS database_state,
    
    -- Full Backup Info
    MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END) AS last_full_backup_time,
    DATEDIFF(HOUR, MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END), GETDATE()) AS hours_since_full_backup,
    MAX(CASE WHEN b.type = 'D' THEN 
        CASE WHEN b.is_damaged = 0 THEN 'Success' ELSE 'Failed' END 
    END) AS last_full_backup_status,
    
    -- Differential Backup Info
    MAX(CASE WHEN b.type = 'I' THEN b.backup_finish_date END) AS last_diff_backup_time,
    DATEDIFF(HOUR, MAX(CASE WHEN b.type = 'I' THEN b.backup_finish_date END), GETDATE()) AS hours_since_diff_backup,
    
    -- Log Backup Info
    MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END) AS last_log_backup_time,
    DATEDIFF(MINUTE, MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END), GETDATE()) AS minutes_since_log_backup,
    
    -- Backup Alerts
    CASE 
        WHEN MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END) IS NULL THEN 'Never'
        WHEN DATEDIFF(HOUR, MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END), GETDATE()) > 168 THEN 'Critical'  -- > 7 days
        WHEN DATEDIFF(HOUR, MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END), GETDATE()) > 24 THEN 'Warning'   -- > 1 day
        ELSE 'OK'
    END AS full_backup_alert_status,
    
    CASE 
        WHEN d.recovery_model_desc = 'SIMPLE' THEN 'N/A'
        WHEN MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END) IS NULL THEN 'Never'
        WHEN DATEDIFF(MINUTE, MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END), GETDATE()) > 60 THEN 'Critical'  -- > 1 hour
        WHEN DATEDIFF(MINUTE, MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END), GETDATE()) > 30 THEN 'Warning'   -- > 30 min
        ELSE 'OK'
    END AS log_backup_alert_status

FROM sys.databases d
LEFT JOIN msdb.dbo.backupset b ON d.name = b.database_name
WHERE d.database_id > 0  -- Include all databases
GROUP BY d.name, d.recovery_model_desc, d.state_desc
ORDER BY d.name
"@

    try {
        $command = New-Object System.Data.SqlClient.SqlCommand($query, $Connection)
        $command.CommandTimeout = 60
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($command)
        $dataTable = New-Object System.Data.DataTable
        $rowCount = $adapter.Fill($dataTable)
        Write-Verbose "Backup status query filled $rowCount rows"
        # Use Write-Output with -NoEnumerate to prevent PowerShell from unwrapping single-row DataTables
        Write-Output -NoEnumerate $dataTable
    }
    catch {
        Write-Warning "Failed to query backup status: $($_.Exception.Message)"
        Write-Warning "This requires SELECT permission on msdb.dbo.backupset"
        throw
    }
}

function Write-ToEventLog {
    <#
    .SYNOPSIS
        Writes JSON content to Windows Event Log
    #>
    param (
        [string]$LogName,
        [string]$Source,
        [string]$Message,
        [int]$EventId,
        [System.Diagnostics.EventLogEntryType]$EntryType = [System.Diagnostics.EventLogEntryType]::Information
    )
    
    try {
        Write-EventLog -LogName $LogName -Source $Source -EventId $EventId -EntryType $EntryType -Message $Message
        Write-Verbose "Successfully wrote event to $LogName"
        return $true
    }
    catch {
        Write-Error "Failed to write to Event Log: $_"
        return $false
    }
}

#endregion Functions

#region Main Script

try {
    Write-Verbose "Starting SQL Server information collection..."
    Write-Verbose "PowerShell Version: $($PSVersionTable.PSVersion)"
    
    # Initialize Event Source
    Initialize-EventSource -LogName $EventLogName -Source $EventSource
    
    # Build connection string based on authentication type
    if ($UseSqlAuthentication) {
        $credential = Get-SqlCredential -CredentialPath $CredentialPath -Username $SqlUsername
        if (-not $credential) {
            throw "SQL Authentication selected but no credentials provided. Use -CredentialPath parameter."
        }
        $username = $credential.UserName
        $password = $credential.GetNetworkCredential().Password
        $connectionString = "Server=$SqlInstance;User Id=$username;Password=$password;TrustServerCertificate=True;"
        Write-Verbose "Using SQL Authentication with user: $username"
    }
    else {
        $connectionString = "Server=$SqlInstance;Integrated Security=True;TrustServerCertificate=True;"
        Write-Verbose "Using Windows Authentication"
    }
    
    # Create and open connection
    $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
    $connection.Open()
    
    Write-Verbose "Connected to SQL Server: $SqlInstance"
    
    # Collect data
    Write-Verbose "Querying instance uptime..."
    $instanceUptime = Get-SqlServerInstanceUptime -Connection $connection
    
    # Check if we got results - handle DataTable properly
    $instanceRowCount = @($instanceUptime.Rows).Count
    Write-Verbose "Instance uptime query returned $instanceRowCount rows"
    
    if ($null -eq $instanceUptime -or $instanceRowCount -eq 0) {
        $connection.Close()
        throw "Failed to query instance uptime. Ensure the SQL login has VIEW SERVER STATE permission. Run: GRANT VIEW SERVER STATE TO [$($credential.UserName)];"
    }
    
    Write-Verbose "Querying database uptime..."
    $databaseUptime = Get-DatabaseUptime -Connection $connection
    Write-Verbose "Database uptime query returned $(@($databaseUptime.Rows).Count) rows"
    
    Write-Verbose "Querying backup status..."
    $backupStatus = Get-DatabaseBackupStatus -Connection $connection
    
    # Check if we got results
    $backupRowCount = @($backupStatus.Rows).Count
    Write-Verbose "Backup status query returned $backupRowCount rows"
    
    if ($null -eq $backupStatus -or $backupRowCount -eq 0) {
        $connection.Close()
        throw "Failed to query backup status. Ensure the SQL login has SELECT permission on msdb.dbo.backupset."
    }
    
    # Close connection
    $connection.Close()
    
    # Build output object
    $currentTime = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $computerName = $env:COMPUTERNAME
    
    # Get the first row from instance uptime
    Write-Verbose "Accessing instance uptime data..."
    Write-Verbose "DataTable type: $($instanceUptime.GetType().FullName)"
    Write-Verbose "Rows type: $($instanceUptime.Rows.GetType().FullName)"
    Write-Verbose "Rows count property: $($instanceUptime.Rows.Count)"
    
    # Try multiple access methods for compatibility
    $instanceRow = $null
    try {
        $instanceRow = $instanceUptime.Rows[0]
        Write-Verbose "Accessed row using index [0]"
    }
    catch {
        Write-Verbose "Index access failed: $_"
        try {
            $instanceRow = $instanceUptime.Rows.Item(0)
            Write-Verbose "Accessed row using .Item(0)"
        }
        catch {
            Write-Verbose "Item access failed: $_"
        }
    }
    
    if ($null -eq $instanceRow) {
        throw "No data returned from instance uptime query. Could not access row data."
    }
    
    Write-Verbose "Row type: $($instanceRow.GetType().FullName)"
    Write-Verbose "Instance start time: $($instanceRow.sqlserver_start_time)"
    
    # Instance information
    $instanceInfo = @{
        ComputerName = $computerName
        SqlInstance = $SqlInstance
        CollectionTimeUtc = $currentTime
        InstanceStartTime = $instanceRow.sqlserver_start_time.ToString("yyyy-MM-ddTHH:mm:ssZ")
        InstanceUptimeSeconds = [int]$instanceRow.uptime_seconds
        InstanceUptimeMinutes = [int]$instanceRow.uptime_minutes
        InstanceUptimeHours = [int]$instanceRow.uptime_hours
        InstanceUptimeDays = [int]$instanceRow.uptime_days
    }
    
    Write-Verbose "Instance info created successfully"
    
    # Database information array
    $databases = @()
    
    Write-Verbose "Processing $($backupStatus.Rows.Count) databases..."
    
    foreach ($db in $backupStatus.Rows) {
        # Find matching uptime row
        $dbUptimeRow = $null
        foreach ($uptimeRow in $databaseUptime.Rows) {
            if ($uptimeRow.database_name -eq $db.database_name) {
                $dbUptimeRow = $uptimeRow
                break
            }
        }
        
        $dbInfo = @{
            DatabaseName = [string]$db.database_name
            DatabaseState = [string]$db.database_state
            RecoveryModel = [string]$db.recovery_model
            
            # Uptime info
            UptimeSeconds = if ($dbUptimeRow -and $dbUptimeRow.uptime_seconds -ne [DBNull]::Value) { [int]$dbUptimeRow.uptime_seconds } else { $null }
            
            # Full backup info
            LastFullBackupTime = if ($db.last_full_backup_time -ne [DBNull]::Value) { 
                $db.last_full_backup_time.ToString("yyyy-MM-ddTHH:mm:ssZ") 
            } else { $null }
            HoursSinceFullBackup = if ($db.hours_since_full_backup -ne [DBNull]::Value) { 
                [int]$db.hours_since_full_backup 
            } else { $null }
            LastFullBackupStatus = if ($db.last_full_backup_status -ne [DBNull]::Value) { 
                [string]$db.last_full_backup_status
            } else { "Never" }
            FullBackupAlertStatus = [string]$db.full_backup_alert_status
            
            # Differential backup info
            LastDiffBackupTime = if ($db.last_diff_backup_time -ne [DBNull]::Value) { 
                $db.last_diff_backup_time.ToString("yyyy-MM-ddTHH:mm:ssZ") 
            } else { $null }
            HoursSinceDiffBackup = if ($db.hours_since_diff_backup -ne [DBNull]::Value) { 
                [int]$db.hours_since_diff_backup 
            } else { $null }
            
            # Log backup info
            LastLogBackupTime = if ($db.last_log_backup_time -ne [DBNull]::Value) { 
                $db.last_log_backup_time.ToString("yyyy-MM-ddTHH:mm:ssZ") 
            } else { $null }
            MinutesSinceLogBackup = if ($db.minutes_since_log_backup -ne [DBNull]::Value) { 
                [int]$db.minutes_since_log_backup 
            } else { $null }
            LogBackupAlertStatus = [string]$db.log_backup_alert_status
        }
        
        $databases += $dbInfo
    }
    
    Write-Verbose "Processed $($databases.Count) databases"
    
    # Final output object
    $output = @{
        EventType = "SQLServerMonitoring"
        Instance = $instanceInfo
        Databases = $databases
    }
    
    # Convert to JSON
    $jsonOutput = $output | ConvertTo-Json -Depth 10 -Compress
    
    # Write to Event Log
    $success = Write-ToEventLog -LogName $EventLogName -Source $EventSource -Message $jsonOutput -EventId $EventId
    
    if ($success) {
        Write-Host "Successfully collected SQL Server information and wrote to Event Log." -ForegroundColor Green
        Write-Host "Event Log: $EventLogName, Source: $EventSource, Event ID: $EventId" -ForegroundColor Cyan
    }
    
    # Also output to console for verification
    Write-Verbose "JSON Output:"
    Write-Verbose $jsonOutput
    
    # Return the object for pipeline usage
    return $output
}
catch {
    $errorMessage = @{
        EventType = "SQLServerMonitoringError"
        ComputerName = $env:COMPUTERNAME
        SqlInstance = $SqlInstance
        CollectionTimeUtc = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        ErrorMessage = $_.Exception.Message
        ErrorDetails = $_.ToString()
    } | ConvertTo-Json -Compress
    
    # Write error to Event Log
    try {
        Write-ToEventLog -LogName $EventLogName -Source $EventSource -Message $errorMessage -EventId ($EventId + 1) -EntryType Error
    }
    catch {
        Write-Warning "Could not write error to Event Log"
    }
    
    Write-Error "Failed to collect SQL Server information: $_"
    throw
}

#endregion Main Script
