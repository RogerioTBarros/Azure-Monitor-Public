<#
.SYNOPSIS
    Azure Automation Runbook - Collects SQL Server information and pushes to Azure Monitor via Logs Ingestion API.
    Output: Custom Log Analytics table via Data Collection Endpoint (DCE)

.DESCRIPTION
    This runbook connects to multiple SQL Server instances from a central Hybrid Worker,
    collects metrics (uptime, backup status), and pushes directly to Azure Monitor 
    using the Logs Ingestion API with Managed Identity authentication.

    Supports two SQL Server authentication methods:
    - Windows Authentication: Uses Hybrid Worker service account (domain environments)
    - SQL Authentication: Retrieves credentials from Azure Key Vault (non-domain/mixed environments)

.PARAMETER SqlInstances
    Optional array of SQL Server instance names to connect to.
    If not provided, the runbook reads from an Automation Account variable (see SqlInstancesVariableName).
    Example: @("Server1", "Server2\Instance1", "10.0.0.5,1433")

.PARAMETER SqlInstancesVariableName
    Name of the Automation Account variable containing the SQL instances list.
    The variable value must be a JSON array of instance strings.
    Example variable value: ["Server1", "Server2\\Instance1", "10.0.0.5,1433"]
    Default: "SqlInstances"
    This is only used when the SqlInstances parameter is not provided.

.PARAMETER SqlAuthenticationType
    The authentication method to use for SQL Server connections.
    Valid values: "Windows", "SQL"
    Default: "Windows"

.PARAMETER KeyVaultName
    Name of the Azure Key Vault containing SQL credentials.
    Required when SqlAuthenticationType is "SQL".
    Example: "my-sql-keyvault"

.PARAMETER SqlUsernameSecretName
    Name of the Key Vault secret containing the SQL username.
    Required when SqlAuthenticationType is "SQL".
    Default: "SqlMonitorUsername"

.PARAMETER SqlPasswordSecretName
    Name of the Key Vault secret containing the SQL password.
    Required when SqlAuthenticationType is "SQL".
    Default: "SqlMonitorPassword"

.PARAMETER DceEndpoint
    The Data Collection Endpoint URI.
    Example: "https://my-dce-abcd.westus2-1.ingest.monitor.azure.com"

.PARAMETER DcrImmutableId
    The immutable ID of the Data Collection Rule.
    Example: "dcr-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

.PARAMETER StreamName
    The stream name in the DCR. Default: "Custom-SQLServerMonitoring_CL"

.PARAMETER ManagedIdentityClientId
    Optional: Client ID for User-assigned Managed Identity.
    If not specified, uses System-assigned Managed Identity.

.EXAMPLE
    # Using Automation Account variable (recommended for production)
    # First, create the variable in the Automation Account:
    #   Name: SqlInstances
    #   Value: ["SQLServer1", "SQLServer2\\Instance1", "10.0.0.5,1433"]
    # Then run the runbook without the SqlInstances parameter:
    .\Get-SQLServerInfo-LogsIngestionApi.ps1 `
        -DceEndpoint "https://my-dce.eastus-1.ingest.monitor.azure.com" `
        -DcrImmutableId "dcr-xxxxxxxx"

.EXAMPLE
    # Windows Authentication with explicit instances (domain-joined servers)
    .\Get-SQLServerInfo-LogsIngestionApi.ps1 `
        -SqlInstances @("SQLServer1", "SQLServer2\Instance1") `
        -SqlAuthenticationType "Windows" `
        -DceEndpoint "https://my-dce.eastus-1.ingest.monitor.azure.com" `
        -DcrImmutableId "dcr-xxxxxxxx"

.EXAMPLE
    # SQL Authentication with Key Vault
    .\Get-SQLServerInfo-LogsIngestionApi.ps1 `
        -SqlInstances @("SQLServer1", "10.0.0.5") `
        -SqlAuthenticationType "SQL" `
        -KeyVaultName "my-sql-keyvault" `
        -SqlUsernameSecretName "SqlMonitorUser" `
        -SqlPasswordSecretName "SqlMonitorPass" `
        -DceEndpoint "https://my-dce.eastus-1.ingest.monitor.azure.com" `
        -DcrImmutableId "dcr-xxxxxxxx"

.EXAMPLE
    # Custom variable name for SQL instances
    .\Get-SQLServerInfo-LogsIngestionApi.ps1 `
        -SqlInstancesVariableName "ProductionSqlInstances" `
        -DceEndpoint "https://my-dce.eastus-1.ingest.monitor.azure.com" `
        -DcrImmutableId "dcr-xxxxxxxx"

.NOTES
    Author: Azure Monitor Assets
    Version: 2.0
    Date: 2024-12-17
    
    Prerequisites:
    - Azure Automation account with Hybrid Worker
    - System-assigned or User-assigned Managed Identity enabled
    - Managed Identity permissions:
      * "Monitoring Metrics Publisher" role on DCR
      * "Key Vault Secrets User" role on Key Vault (for SQL Auth)
    - Data Collection Endpoint (DCE) created
    - Data Collection Rule (DCR) for custom logs configured
    - Custom table (SQLServerMonitoring_CL) created in Log Analytics
    
    For SQL Authentication:
    - Key Vault with SQL credentials stored as secrets
    - Managed Identity granted access to Key Vault secrets
#>

param (
    [Parameter(Mandatory = $false)]
    [string[]]$SqlInstances,

    [Parameter(Mandatory = $false)]
    [string]$SqlInstancesVariableName = "SqlInstances",

    [Parameter(Mandatory = $false)]
    [ValidateSet("Windows", "SQL")]
    [string]$SqlAuthenticationType = "Windows",

    [Parameter(Mandatory = $false)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $false)]
    [string]$SqlUsernameSecretName = "SqlMonitorUsername",

    [Parameter(Mandatory = $false)]
    [string]$SqlPasswordSecretName = "SqlMonitorPassword",

    [Parameter(Mandatory = $true)]
    [string]$DceEndpoint,

    [Parameter(Mandatory = $true)]
    [string]$DcrImmutableId,

    [Parameter(Mandatory = $false)]
    [string]$StreamName = "Custom-SQLServerMonitoring_CL",

    [Parameter(Mandatory = $false)]
    [string]$ManagedIdentityClientId  # Optional: for User-assigned Managed Identity
)

#region Functions

function Get-AzureAccessToken {
    <#
    .SYNOPSIS
        Gets an Azure access token using Managed Identity.
        Supports Azure Automation cloud sandbox (IDENTITY_ENDPOINT) and
        Arc-enabled Hybrid Workers (localhost:40342 IMDS endpoint).
    #>
    param (
        [string]$Resource = "https://monitor.azure.com/",
        [string]$ClientId
    )
    
    # --- Strategy 1: Azure Automation sandbox identity endpoint ---
    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        try {
            Write-Host "Using Automation sandbox identity endpoint"
            if ($ClientId) {
                $tokenAuthUri = "$env:IDENTITY_ENDPOINT?resource=$Resource&client_id=$ClientId&api-version=2019-08-01"
            }
            else {
                $tokenAuthUri = "$env:IDENTITY_ENDPOINT?resource=$Resource&api-version=2019-08-01"
            }
            
            $response = Invoke-RestMethod -Uri $tokenAuthUri -Method Get -Headers @{
                "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER
            } -UseBasicParsing
            
            return $response.access_token
        }
        catch {
            Write-Warning "Automation sandbox identity failed: $_. Falling back to Arc IMDS."
        }
    }
    
    # --- Strategy 2: Arc-enabled server IMDS endpoint (Hybrid Worker on Arc VM) ---
    try {
        Write-Host "Using Arc IMDS identity endpoint (localhost:40342)"
        $arcImdsBase = "http://localhost:40342/metadata/identity/oauth2/token"
        if ($ClientId) {
            $tokenAuthUri = "${arcImdsBase}?resource=$Resource&client_id=$ClientId&api-version=2020-06-01"
        }
        else {
            $tokenAuthUri = "${arcImdsBase}?resource=$Resource&api-version=2020-06-01"
        }

        # Arc IMDS uses a challenge-response flow:
        # 1. First request returns 401 with WWW-Authenticate header containing a file path
        # 2. Read the challenge token from that file
        # 3. Retry with the token in the Authorization header
        # Using -SkipHttpErrorCheck (PS 7+) to handle the 401 without exception
        $initialResponse = Invoke-WebRequest -Uri $tokenAuthUri -Method Get -Headers @{ "Metadata" = "true" } -UseBasicParsing -SkipHttpErrorCheck

        if ($initialResponse.StatusCode -eq 401) {
            # Extract challenge token file path from WWW-Authenticate header
            $wwwAuth = $initialResponse.Headers["WWW-Authenticate"]
            # PS7 returns headers as string arrays - join all elements
            if ($wwwAuth -is [array]) { $wwwAuth = $wwwAuth -join ' ' }
            $wwwAuth = $wwwAuth -replace '[\r\n]+', ' '  # normalize any newlines
            
            Write-Host "Got 401 challenge, WWW-Authenticate: $wwwAuth"
            
            # Handle both quoted and unquoted realm values, with flexible whitespace
            if ($wwwAuth -match 'realm=\"?([A-Za-z]:\\[^\"\s]+)') {
                $challengeTokenPath = $matches[1]
                Write-Host "Reading challenge token from: $challengeTokenPath"
                $challengeToken = Get-Content -Path $challengeTokenPath -Raw -ErrorAction Stop
                
                $tokenResponse = Invoke-RestMethod -Uri $tokenAuthUri -Method Get -Headers @{
                    "Metadata"      = "true"
                    "Authorization" = "Basic $challengeToken"
                } -UseBasicParsing
                
                return $tokenResponse.access_token
            }
            else {
                throw "Arc IMDS challenge flow failed. WWW-Authenticate header: '$wwwAuth'"
            }
        }
        elseif ($initialResponse.StatusCode -eq 200) {
            $tokenData = $initialResponse.Content | ConvertFrom-Json
            return $tokenData.access_token
        }
        else {
            throw "Arc IMDS returned unexpected status $($initialResponse.StatusCode): $($initialResponse.Content)"
        }
    }
    catch {
        Write-Error "Failed to get access token for resource '$Resource': $_"
        throw
    }
}

function Get-KeyVaultSecret {
    <#
    .SYNOPSIS
        Retrieves a secret value from Azure Key Vault using Managed Identity
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$VaultName,
        
        [Parameter(Mandatory = $true)]
        [string]$SecretName,
        
        [Parameter(Mandatory = $false)]
        [string]$ClientId
    )
    
    try {
        # Get access token for Key Vault
        $kvToken = Get-AzureAccessToken -Resource "https://vault.azure.net" -ClientId $ClientId
        
        # Get secret from Key Vault
        $uri = "https://$VaultName.vault.azure.net/secrets/${SecretName}?api-version=7.4"
        
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers @{
            "Authorization" = "Bearer $kvToken"
            "Content-Type"  = "application/json"
        } -UseBasicParsing
        
        return $response.value
    }
    catch {
        Write-Error "Failed to get secret '$SecretName' from Key Vault '$VaultName': $_"
        throw
    }
}

function Get-SqlCredentialFromKeyVault {
    <#
    .SYNOPSIS
        Retrieves SQL credentials from Azure Key Vault and returns a PSCredential object
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$VaultName,
        
        [Parameter(Mandatory = $true)]
        [string]$UsernameSecretName,
        
        [Parameter(Mandatory = $true)]
        [string]$PasswordSecretName,
        
        [Parameter(Mandatory = $false)]
        [string]$ClientId
    )
    
    Write-Host "Retrieving SQL credentials from Key Vault: $VaultName"
    
    $username = Get-KeyVaultSecret -VaultName $VaultName -SecretName $UsernameSecretName -ClientId $ClientId
    $password = Get-KeyVaultSecret -VaultName $VaultName -SecretName $PasswordSecretName -ClientId $ClientId
    
    $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($username, $securePassword)
    
    Write-Host "Successfully retrieved SQL credentials (Username: $username)"
    return $credential
}

function Send-ToLogsIngestionApi {
    <#
    .SYNOPSIS
        Sends data to Azure Monitor using Logs Ingestion API
    #>
    param (
        [string]$DceEndpoint,
        [string]$DcrImmutableId,
        [string]$StreamName,
        [string]$AccessToken,
        [array]$Data
    )
    
    $uri = "$DceEndpoint/dataCollectionRules/$DcrImmutableId/streams/${StreamName}?api-version=2023-01-01"
    
    $headers = @{
        "Authorization" = "Bearer $AccessToken"
        "Content-Type"  = "application/json"
    }
    
    $body = $Data | ConvertTo-Json -Depth 10 -AsArray
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -UseBasicParsing
        Write-Host "Successfully sent $($Data.Count) record(s) to Azure Monitor"
        return $true
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorMessage = $_.ErrorDetails.Message
        Write-Error "Failed to send data to Logs Ingestion API. Status: $statusCode, Error: $errorMessage"
        return $false
    }
}

function Get-SqlServerData {
    <#
    .SYNOPSIS
        Connects to SQL Server and retrieves monitoring data
    #>
    param (
        [string]$SqlInstance,
        [System.Management.Automation.PSCredential]$Credential
    )
    
    # Build connection string
    if ($Credential) {
        $username = $Credential.UserName
        $password = $Credential.GetNetworkCredential().Password
        $connectionString = "Server=$SqlInstance;User Id=$username;Password=$password;TrustServerCertificate=True;Connection Timeout=30;"
    }
    else {
        $connectionString = "Server=$SqlInstance;Integrated Security=True;TrustServerCertificate=True;Connection Timeout=30;"
    }
    
    # Ensure System.Data.SqlClient is available (needed for PS 7.x on Hybrid Worker)
    try { [void][System.Data.SqlClient.SqlConnection] } catch {
        Add-Type -AssemblyName "System.Data" -ErrorAction SilentlyContinue
    }
    
    $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
    
    try {
        $connection.Open()
        Write-Host "Connected to: $SqlInstance"
        
        # Query 1: Instance Uptime
        $instanceQuery = @"
SELECT 
    @@SERVERNAME AS server_name,
    @@VERSION AS sql_version,
    sqlserver_start_time,
    DATEDIFF(SECOND, sqlserver_start_time, GETDATE()) AS uptime_seconds
FROM sys.dm_os_sys_info
"@
        
        $command = New-Object System.Data.SqlClient.SqlCommand($instanceQuery, $connection)
        $command.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($command)
        $instanceTable = New-Object System.Data.DataTable
        $adapter.Fill($instanceTable) | Out-Null
        
        # Query 2: Database Backup Status
        $backupQuery = @"
SELECT 
    d.name AS database_name,
    d.recovery_model_desc AS recovery_model,
    d.state_desc AS database_state,
    d.create_date AS database_create_date,
    MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END) AS last_full_backup_time,
    DATEDIFF(HOUR, MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END), GETDATE()) AS hours_since_full_backup,
    MAX(CASE WHEN b.type = 'D' THEN 
        CASE WHEN b.is_damaged = 0 THEN 'Success' ELSE 'Failed' END 
    END) AS last_full_backup_status,
    MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END) AS last_log_backup_time,
    DATEDIFF(MINUTE, MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END), GETDATE()) AS minutes_since_log_backup,
    CASE 
        WHEN MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END) IS NULL THEN 'Never'
        WHEN DATEDIFF(HOUR, MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END), GETDATE()) > 168 THEN 'Critical'
        WHEN DATEDIFF(HOUR, MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END), GETDATE()) > 24 THEN 'Warning'
        ELSE 'OK'
    END AS full_backup_alert_status
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset b ON d.name = b.database_name
WHERE d.database_id > 0
GROUP BY d.name, d.recovery_model_desc, d.state_desc, d.create_date
"@
        
        $command2 = New-Object System.Data.SqlClient.SqlCommand($backupQuery, $connection)
        $command2.CommandTimeout = 60
        $adapter2 = New-Object System.Data.SqlClient.SqlDataAdapter($command2)
        $backupTable = New-Object System.Data.DataTable
        $adapter2.Fill($backupTable) | Out-Null
        
        $connection.Close()
        
        return @{
            Success = $true
            InstanceData = $instanceTable
            BackupData = $backupTable
        }
    }
    catch {
        if ($connection.State -eq 'Open') { $connection.Close() }
        Write-Warning "Failed to connect to ${SqlInstance}: $_"
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function ConvertTo-LogAnalyticsRecord {
    <#
    .SYNOPSIS
        Converts SQL Server data to Log Analytics record format
    #>
    param (
        [string]$SqlInstance,
        [System.Data.DataTable]$InstanceData,
        [System.Data.DataTable]$BackupData,
        [string]$CollectorName,
        [datetime]$CollectionTime
    )
    
    $records = @()
    $instanceRow = $InstanceData.Rows | Select-Object -First 1
    
    # Create a record for each database
    foreach ($db in $BackupData.Rows) {
        $record = [ordered]@{
            TimeGenerated              = $CollectionTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
            CollectorName              = $CollectorName
            SqlInstance                = $SqlInstance
            ServerName                 = [string]$instanceRow.server_name
            SqlVersion                 = ([string]$instanceRow.sql_version).Split("`n")[0].Trim()  # First line only
            InstanceStartTime          = $instanceRow.sqlserver_start_time.ToString("yyyy-MM-ddTHH:mm:ssZ")
            InstanceUptimeSeconds      = [int]$instanceRow.uptime_seconds
            InstanceUptimeMinutes      = [int]($instanceRow.uptime_seconds / 60)
            InstanceUptimeHours        = [int]($instanceRow.uptime_seconds / 3600)
            InstanceUptimeDays         = [int]($instanceRow.uptime_seconds / 86400)
            DatabaseName               = [string]$db.database_name
            DatabaseState              = [string]$db.database_state
            RecoveryModel              = [string]$db.recovery_model
            DatabaseCreateDate         = $db.database_create_date.ToString("yyyy-MM-ddTHH:mm:ssZ")
            LastFullBackupTime         = if ($db.last_full_backup_time -ne [DBNull]::Value) { 
                                            $db.last_full_backup_time.ToString("yyyy-MM-ddTHH:mm:ssZ") 
                                         } else { "" }
            HoursSinceFullBackup       = if ($db.hours_since_full_backup -ne [DBNull]::Value) { 
                                            [int]$db.hours_since_full_backup 
                                         } else { -1 }
            LastFullBackupStatus       = if ($db.last_full_backup_status -ne [DBNull]::Value) { 
                                            [string]$db.last_full_backup_status 
                                         } else { "Never" }
            FullBackupAlertStatus      = [string]$db.full_backup_alert_status
            LastLogBackupTime          = if ($db.last_log_backup_time -ne [DBNull]::Value) { 
                                            $db.last_log_backup_time.ToString("yyyy-MM-ddTHH:mm:ssZ") 
                                         } else { "" }
            MinutesSinceLogBackup      = if ($db.minutes_since_log_backup -ne [DBNull]::Value) { 
                                            [int]$db.minutes_since_log_backup 
                                         } else { -1 }
        }
        $records += $record
    }
    
    return $records
}

#endregion Functions

#region Main Script

# Resolve SQL Instances: use parameter if provided, otherwise read from Automation Account variable
if (-not $SqlInstances -or $SqlInstances.Count -eq 0) {
    Write-Output "SqlInstances parameter not provided. Reading from Automation Account variable: '$SqlInstancesVariableName'"
    try {
        $variableValue = Get-AutomationVariable -Name $SqlInstancesVariableName
        if (-not $variableValue) {
            throw "Variable '$SqlInstancesVariableName' is empty or not found."
        }
        Write-Output "Variable raw value: $variableValue"
        
        # Parse JSON array or comma-separated string
        if ($variableValue.Trim().StartsWith('[')) {
            # JSON array format: ["Server1", "Server2\Instance1", "10.0.0.5,1433"]
            $SqlInstances = $variableValue | ConvertFrom-Json
        } else {
            # Comma-separated format (legacy): Server1,Server2\Instance1
            # Note: instances with port (e.g. 10.0.0.5,1433) must use JSON format
            $SqlInstances = $variableValue -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        }
        
        Write-Output "Loaded $($SqlInstances.Count) SQL instance(s) from Automation variable '$SqlInstancesVariableName'"
    }
    catch {
        Write-Error "Failed to read SQL instances from Automation Account variable '$SqlInstancesVariableName': $_"
        Write-Error "Create the variable in Azure Portal > Automation Account > Variables, or provide the -SqlInstances parameter."
        throw
    }
} else {
    Write-Output "Using SQL instances from parameter"
    # Sanitize SqlInstances - Azure Automation array serialization may add brackets
    $SqlInstances = $SqlInstances | ForEach-Object { $_.Trim().TrimStart('[').TrimEnd(']').Trim() } | Where-Object { $_ -ne '' }
}

if ($SqlInstances.Count -eq 0) {
    Write-Error "No SQL instances to monitor. Provide instances via the -SqlInstances parameter or the '$SqlInstancesVariableName' Automation Account variable."
    throw "No SQL instances configured."
}

Write-Output "======================================"
Write-Output "SQL Server Monitoring - Logs Ingestion API"
Write-Output "======================================"
Write-Output "Collecting from $($SqlInstances.Count) SQL instance(s)"
Write-Output "Authentication Type: $SqlAuthenticationType"
Write-Output "DCE Endpoint: $DceEndpoint"
Write-Output "DCR Immutable ID: $DcrImmutableId"
Write-Output "Stream Name: $StreamName"
Write-Output ""

# Validate parameters for SQL Authentication
if ($SqlAuthenticationType -eq "SQL") {
    if (-not $KeyVaultName) {
        Write-Error "KeyVaultName is required when using SQL Authentication"
        throw "Missing required parameter: KeyVaultName"
    }
    Write-Output "Key Vault: $KeyVaultName"
    Write-Output "Username Secret: $SqlUsernameSecretName"
    Write-Output "Password Secret: $SqlPasswordSecretName"
}

Write-Output ""

# Get access token for Azure Monitor
Write-Output "Authenticating with Managed Identity..."
$accessToken = Get-AzureAccessToken -Resource "https://monitor.azure.com/" -ClientId $ManagedIdentityClientId
Write-Output "Successfully obtained access token for Azure Monitor"

# Get SQL credentials based on authentication type
$sqlCredential = $null

switch ($SqlAuthenticationType) {
    "Windows" {
        Write-Output "Using Windows Authentication (Hybrid Worker service account)"
        Write-Output "  Service Account: $env:USERNAME"
    }
    "SQL" {
        try {
            $sqlCredential = Get-SqlCredentialFromKeyVault `
                -VaultName $KeyVaultName `
                -UsernameSecretName $SqlUsernameSecretName `
                -PasswordSecretName $SqlPasswordSecretName `
                -ClientId $ManagedIdentityClientId
        }
        catch {
            Write-Error "Failed to retrieve SQL credentials from Key Vault: $_"
            throw
        }
    }
}

$collectionTime = [datetime]::UtcNow
$collectorName = $env:COMPUTERNAME
$allRecords = @()
$results = @()

foreach ($sqlInstance in $SqlInstances) {
    Write-Output "`nProcessing: $sqlInstance"
    
    $data = Get-SqlServerData -SqlInstance $sqlInstance -Credential $sqlCredential
    
    if ($data.Success) {
        $records = ConvertTo-LogAnalyticsRecord `
            -SqlInstance $sqlInstance `
            -InstanceData $data.InstanceData `
            -BackupData $data.BackupData `
            -CollectorName $collectorName `
            -CollectionTime $collectionTime
        
        $allRecords += $records
        Write-Output "  Collected $($records.Count) database records"
        
        $results += @{
            SqlInstance = $sqlInstance
            Status = "Success"
            RecordCount = $records.Count
        }
    }
    else {
        # Add error record
        $errorRecord = [ordered]@{
            TimeGenerated         = $collectionTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
            CollectorName         = $collectorName
            SqlInstance           = $sqlInstance
            ServerName            = ""
            SqlVersion            = ""
            InstanceStartTime     = ""
            InstanceUptimeSeconds = -1
            InstanceUptimeMinutes = -1
            InstanceUptimeHours   = -1
            InstanceUptimeDays    = -1
            DatabaseName          = "_ERROR"
            DatabaseState         = "ConnectionError"
            RecoveryModel         = ""
            DatabaseCreateDate    = ""
            LastFullBackupTime    = ""
            HoursSinceFullBackup  = -1
            LastFullBackupStatus  = "Error: $($data.Error)"
            FullBackupAlertStatus = "Error"
            LastLogBackupTime     = ""
            MinutesSinceLogBackup = -1
        }
        $allRecords += $errorRecord
        
        $results += @{
            SqlInstance = $sqlInstance
            Status = "Failed"
            Error = $data.Error
        }
    }
}

# Send all records to Azure Monitor
if ($allRecords.Count -gt 0) {
    Write-Output "`nSending $($allRecords.Count) total records to Azure Monitor..."
    $sendResult = Send-ToLogsIngestionApi `
        -DceEndpoint $DceEndpoint `
        -DcrImmutableId $DcrImmutableId `
        -StreamName $StreamName `
        -AccessToken $accessToken `
        -Data $allRecords
    
    if (-not $sendResult) {
        Write-Error "Failed to send data to Azure Monitor"
    }
}
else {
    Write-Warning "No records to send"
}

Write-Output "`n=== Collection Summary ==="
$results | ForEach-Object {
    $status = if ($_.RecordCount) { "$($_.Status) ($($_.RecordCount) records)" } else { "$($_.Status) - $($_.Error)" }
    Write-Output "$($_.SqlInstance): $status"
}

Write-Output "`nTotal records sent: $($allRecords.Count)"
Write-Output "Collection complete!"

#endregion Main Script
