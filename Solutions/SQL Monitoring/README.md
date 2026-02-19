# SQL Server Monitoring for Azure Monitor

This solution collects SQL Server metrics and writes them to Windows Event Log in JSON format for ingestion into Azure Monitor Logs via Data Collection Rules (DCR).

## Collected Metrics

| Metric | Description |
|--------|-------------|
| **Instance Uptime** | SQL Server instance start time and uptime (seconds/minutes/hours/days) |
| **Database Uptime** | Time since each database came online |
| **Last Full Backup Time** | When the last full backup completed |
| **Last Full Backup Status** | Success/Failed status of last full backup |
| **Last Differential Backup Time** | When the last differential backup completed |
| **Last Log Backup Time** | When the last transaction log backup completed |
| **Backup Alert Status** | OK/Warning/Critical based on backup age |

## Prerequisites

1. **SQL Server Permissions**: The account running the script needs:
   - `VIEW SERVER STATE` permission
   - `SELECT` permission on `msdb.dbo.backupset`
   - Access to `sys.databases`, `sys.dm_os_sys_info`, `sys.dm_exec_sessions`

2. **Windows Permissions**: 
   - Administrator rights to create Event Source (first run only)
   - Write access to Windows Event Log

3. **Azure Monitor Agent** installed on the VM

## Installation

### Option A: Non-Domain Joined Server with SQL Authentication (Recommended)

For standalone servers or lab environments using SQL Server mixed authentication mode.

#### Step 1: Create SQL Login for Monitoring

Connect to SQL Server as SA or admin and run:

```sql
USE [master]
GO

-- Create a dedicated login for monitoring
CREATE LOGIN [SQLMonitorReader] WITH PASSWORD = 'YourStrongPassword123!';
GO

-- Grant required server-level permissions
GRANT VIEW SERVER STATE TO [SQLMonitorReader];
GO

-- Grant access to msdb for backup history
USE [msdb]
GO
CREATE USER [SQLMonitorReader] FOR LOGIN [SQLMonitorReader];
GO
GRANT SELECT ON [dbo].[backupset] TO [SQLMonitorReader];
GO
```

#### Step 2: Copy the Script

Copy `Get-SQLServerInfo.ps1` to a folder on the SQL Server VM:
```powershell
New-Item -ItemType Directory -Path "C:\Scripts\SQLMonitoring" -Force
Copy-Item "Get-SQLServerInfo.ps1" -Destination "C:\Scripts\SQLMonitoring\"
```

#### Step 3: Create Local Windows User for Scheduled Task

Create a local user that will run the scheduled task:

```powershell
# Create local user for the scheduled task
$password = Read-Host -AsSecureString "Enter password for SQLTaskUser"
New-LocalUser -Name "SQLTaskUser" -Password $password -Description "SQL Monitoring Task Account" -PasswordNeverExpires

# Add to Users group
Add-LocalGroupMember -Group "Users" -Member "SQLTaskUser"

# IMPORTANT: Add to Event Log Writers group to allow writing to Event Log
Add-LocalGroupMember -Group "Event Log Readers" -Member "SQLTaskUser"
```

#### Step 4: Create Event Source (Run as Administrator - One Time)

The Event Source must be created by an Administrator before SQLTaskUser can write to it:

```powershell
# Run this as Administrator BEFORE running the scheduled task
New-EventLog -LogName "Application" -Source "SQLServerMonitor"

# Verify it was created
[System.Diagnostics.EventLog]::SourceExists("SQLServerMonitor")
```

#### Step 5: Grant Event Log Write Permissions (Run as Administrator)

Grant the SQLTaskUser permission to write to the Application log:

```powershell
# Run as Administrator
$acl = Get-Acl "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application"
$rule = New-Object System.Security.AccessControl.RegistryAccessRule("SQLTaskUser", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.SetAccessRule($rule)
Set-Acl "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application" $acl
```

Or use the simpler approach - add SQLTaskUser to Administrators group (less secure but simpler for lab):

```powershell
# Alternative: Add to Administrators (simpler for lab environments)
Add-LocalGroupMember -Group "Administrators" -Member "SQLTaskUser"
```

#### Step 6: Save SQL Credentials (Run as SQLTaskUser)

**Important**: You must run this step logged in as the SQLTaskUser (or use `runas`), because the credential file is encrypted to the user profile.

```powershell
# Option 1: Log in as SQLTaskUser and run PowerShell
# Option 2: Use runas
runas /user:SQLTaskUser "powershell.exe"

# Then in that PowerShell session:
cd C:\Scripts\SQLMonitoring

# Dot-source the script to load the Save-SqlCredential function
. .\Get-SQLServerInfo.ps1

# Save the credentials (you'll be prompted for the password)
Save-SqlCredential -Path "C:\Scripts\SQLMonitoring\sqlcred.xml" -Username "SQLMonitorReader"
```

#### Step 6: Save SQL Credentials (Run as SQLTaskUser)

**Important**: You must run this step logged in as the SQLTaskUser (or use `runas`), because the credential file is encrypted to the user profile.

```powershell
# Option 1: Log in as SQLTaskUser and run PowerShell
# Option 2: Use runas
runas /user:SQLTaskUser "powershell.exe"

# Then in that PowerShell session:
cd C:\Scripts\SQLMonitoring

# Dot-source the script to load the Save-SqlCredential function
. .\Get-SQLServerInfo.ps1

# Save the credentials (you'll be prompted for the password)
Save-SqlCredential -Path "C:\Scripts\SQLMonitoring\sqlcred.xml" -Username "SQLMonitorReader"
```

#### Step 7: Test the Script (as SQLTaskUser)

```powershell
runas /user:SQLTaskUser "powershell.exe -ExecutionPolicy Bypass -File C:\Scripts\SQLMonitoring\Get-SQLServerInfo.ps1 -SqlInstance localhost -UseSqlAuthentication -CredentialPath C:\Scripts\SQLMonitoring\sqlcred.xml -Verbose"
```

#### Step 8: Create Scheduled Task

```powershell
# Create the scheduled task action
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\SQLMonitoring\Get-SQLServerInfo.ps1" -SqlInstance "localhost" -UseSqlAuthentication -CredentialPath "C:\Scripts\SQLMonitoring\sqlcred.xml"'

# Run every 5 minutes
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 9999)

# Run as the local SQLTaskUser
$principal = New-ScheduledTaskPrincipal -UserId "SQLTaskUser" -LogonType Password -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

# You'll be prompted for SQLTaskUser's password
Register-ScheduledTask -TaskName "SQL Server Monitoring" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Collects SQL Server metrics for Azure Monitor"
```

### Option B: Domain-Joined Server with Windows Authentication

For domain-joined servers, you can use Windows Authentication with a service account.

#### Step 1: Copy the Script

```powershell
New-Item -ItemType Directory -Path "C:\Scripts\SQLMonitoring" -Force
Copy-Item "Get-SQLServerInfo.ps1" -Destination "C:\Scripts\SQLMonitoring\"
```

#### Step 2: Grant SQL Permissions to the Service Account

```sql
USE [master]
GO
CREATE LOGIN [DOMAIN\ServiceAccount] FROM WINDOWS;
GRANT VIEW SERVER STATE TO [DOMAIN\ServiceAccount];
GO

USE [msdb]
GO
CREATE USER [DOMAIN\ServiceAccount] FOR LOGIN [DOMAIN\ServiceAccount];
GRANT SELECT ON [dbo].[backupset] TO [DOMAIN\ServiceAccount];
GO
```

#### Step 3: Create Event Source

```powershell
New-EventLog -LogName "Application" -Source "SQLServerMonitor"
```

#### Step 4: Create Scheduled Task

```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\SQLMonitoring\Get-SQLServerInfo.ps1" -SqlInstance "localhost"'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 9999)
$principal = New-ScheduledTaskPrincipal -UserId "DOMAIN\ServiceAccount" -LogonType Password -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd

Register-ScheduledTask -TaskName "SQL Server Monitoring" -Action $action -Trigger $trigger -Principal $principal -Settings $settings
```

### Using Task Scheduler GUI

1. Open Task Scheduler
2. Create Basic Task: "SQL Server Monitoring"
3. Trigger: Daily, repeat every 5 minutes
4. Action: Start a Program
   - Program: `powershell.exe`
   - For SQL Auth: `-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\SQLMonitoring\Get-SQLServerInfo.ps1" -UseSqlAuthentication -CredentialPath "C:\Scripts\SQLMonitoring\sqlcred.xml"`
   - For Windows Auth: `-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\SQLMonitoring\Get-SQLServerInfo.ps1"`
5. Run with highest privileges
6. Run whether user is logged on or not
7. Configure for: Windows Server 2016/2019/2022/2025

## Azure Monitor Configuration

### Step 1: Create Data Collection Rule (DCR)

Create a DCR to collect the Windows Events:

```json
{
    "properties": {
        "dataSources": {
            "windowsEventLogs": [
                {
                    "name": "SQLServerMonitorEvents",
                    "streams": [
                        "Microsoft-Event"
                    ],
                    "xPathQueries": [
                        "Application!*[System[Provider[@Name='SQLServerMonitor'] and (EventID=1000 or EventID=1001)]]"
                    ]
                }
            ]
        },
        "destinations": {
            "logAnalytics": [
                {
                    "workspaceResourceId": "/subscriptions/{subscription-id}/resourceGroups/{resource-group}/providers/Microsoft.OperationalInsights/workspaces/{workspace-name}",
                    "name": "yourWorkspace"
                }
            ]
        },
        "dataFlows": [
            {
                "streams": [
                    "Microsoft-Event"
                ],
                "destinations": [
                    "yourWorkspace"
                ]
            }
        ]
    }
}
```

If using a custom Event Log (e.g., "SQLServerMonitor"):
```json
"xPathQueries": [
    "SQLServerMonitor!*[System[Provider[@Name='SQLServerMonitor']]]"
]
```

### Step 2: Associate DCR with VM

Associate the DCR with your SQL Server VM through the Azure Portal or ARM template.

## Querying Data in Log Analytics

### Parse JSON from Event Data

```kql
Event
| where Source == "SQLServerMonitor" and EventID == 1000
| extend JsonData = parse_json(RenderedDescription)
| extend 
    ComputerName = tostring(JsonData.Instance.ComputerName),
    SqlInstance = tostring(JsonData.Instance.SqlInstance),
    InstanceUptimeDays = toint(JsonData.Instance.InstanceUptimeDays),
    InstanceStartTime = todatetime(JsonData.Instance.InstanceStartTime)
| project TimeGenerated, ComputerName, SqlInstance, InstanceUptimeDays, InstanceStartTime
```

### Get Database Backup Status

```kql
Event
| where Source == "SQLServerMonitor" and EventID == 1000
| extend JsonData = parse_json(RenderedDescription)
| mv-expand Database = JsonData.Databases
| extend 
    ComputerName = tostring(JsonData.Instance.ComputerName),
    DatabaseName = tostring(Database.DatabaseName),
    DatabaseState = tostring(Database.DatabaseState),
    LastFullBackupTime = todatetime(Database.LastFullBackupTime),
    HoursSinceFullBackup = toint(Database.HoursSinceFullBackup),
    FullBackupAlertStatus = tostring(Database.FullBackupAlertStatus),
    LastLogBackupTime = todatetime(Database.LastLogBackupTime),
    LogBackupAlertStatus = tostring(Database.LogBackupAlertStatus)
| project TimeGenerated, ComputerName, DatabaseName, DatabaseState, 
          LastFullBackupTime, HoursSinceFullBackup, FullBackupAlertStatus,
          LastLogBackupTime, LogBackupAlertStatus
```

### Alert on Missing Backups

```kql
Event
| where Source == "SQLServerMonitor" and EventID == 1000
| where TimeGenerated > ago(1h)
| extend JsonData = parse_json(RenderedDescription)
| mv-expand Database = JsonData.Databases
| where tostring(Database.FullBackupAlertStatus) in ("Critical", "Warning", "Never")
| extend 
    ComputerName = tostring(JsonData.Instance.ComputerName),
    DatabaseName = tostring(Database.DatabaseName),
    AlertStatus = tostring(Database.FullBackupAlertStatus),
    HoursSinceBackup = toint(Database.HoursSinceFullBackup)
| project TimeGenerated, ComputerName, DatabaseName, AlertStatus, HoursSinceBackup
```

### Instance Uptime Monitoring

```kql
Event
| where Source == "SQLServerMonitor" and EventID == 1000
| extend JsonData = parse_json(RenderedDescription)
| summarize arg_max(TimeGenerated, *) by tostring(JsonData.Instance.SqlInstance)
| extend 
    SqlInstance = tostring(JsonData.Instance.SqlInstance),
    InstanceStartTime = todatetime(JsonData.Instance.InstanceStartTime),
    UptimeDays = toint(JsonData.Instance.InstanceUptimeDays)
| project TimeGenerated, SqlInstance, InstanceStartTime, UptimeDays
```

### Database Uptime in Minutes

```kql
Event
| where Source == "SQLServerMonitor" and EventID == 1000
| extend JsonData = parse_json(RenderedDescription)
| mv-expand Database = JsonData.Databases
| extend 
    ComputerName = tostring(JsonData.Instance.ComputerName),
    SqlInstance = tostring(JsonData.Instance.SqlInstance),
    DatabaseName = tostring(Database.DatabaseName),
    DatabaseState = tostring(Database.DatabaseState),
    UptimeSeconds = toint(Database.UptimeSeconds),
    UptimeMinutes = toint(Database.UptimeSeconds) / 60,
    UptimeHours = toint(Database.UptimeSeconds) / 3600,
    UptimeDays = toint(Database.UptimeSeconds) / 86400
| project TimeGenerated, ComputerName, SqlInstance, DatabaseName, DatabaseState, 
          UptimeMinutes, UptimeHours, UptimeDays
| order by DatabaseName asc
```

## Sample JSON Output

```json
{
  "EventType": "SQLServerMonitoring",
  "Instance": {
    "ComputerName": "SQLSERVER01",
    "SqlInstance": "localhost",
    "CollectionTimeUtc": "2024-12-09T14:30:00Z",
    "InstanceStartTime": "2024-12-01T08:00:00Z",
    "InstanceUptimeSeconds": 712800,
    "InstanceUptimeMinutes": 11880,
    "InstanceUptimeHours": 198,
    "InstanceUptimeDays": 8
  },
  "Databases": [
    {
      "DatabaseName": "MyDatabase",
      "DatabaseState": "ONLINE",
      "RecoveryModel": "FULL",
      "UptimeSeconds": 712800,
      "LastFullBackupTime": "2024-12-08T23:00:00Z",
      "HoursSinceFullBackup": 15,
      "LastFullBackupStatus": "Success",
      "FullBackupAlertStatus": "OK",
      "LastDiffBackupTime": null,
      "HoursSinceDiffBackup": null,
      "LastLogBackupTime": "2024-12-09T14:15:00Z",
      "MinutesSinceLogBackup": 15,
      "LogBackupAlertStatus": "OK"
    }
  ]
}
```

## Troubleshooting

### Event Source Already Exists
```powershell
# Check if source exists
[System.Diagnostics.EventLog]::SourceExists("SQLServerMonitor")

# Remove and recreate if needed (requires restart)
Remove-EventLog -Source "SQLServerMonitor"
```

### Event Log Permission Denied

If you get "Access Denied" when writing to Event Log:

```powershell
# Option 1: Verify Event Source was created (run as Admin)
[System.Diagnostics.EventLog]::SourceExists("SQLServerMonitor")

# Option 2: Grant registry permissions to the user (run as Admin)
$user = "SQLTaskUser"  # Change to your username
$acl = Get-Acl "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application"
$rule = New-Object System.Security.AccessControl.RegistryAccessRule($user, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.SetAccessRule($rule)
Set-Acl "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application" $acl

# Option 3: For lab environments, add user to Administrators
Add-LocalGroupMember -Group "Administrators" -Member "SQLTaskUser"

# Option 4: Use SYSTEM account for scheduled task (simplest)
# SYSTEM has full access to Event Logs
```

### Using SYSTEM Account (Simplest Approach for Labs)

If you prefer simplicity over separation of concerns, you can run the scheduled task as SYSTEM:

```powershell
# Store credentials accessible by SYSTEM (run as Admin)
# First, create a folder only SYSTEM can access
$credPath = "C:\ProgramData\SQLMonitoring"
New-Item -ItemType Directory -Path $credPath -Force
icacls $credPath /inheritance:r /grant "SYSTEM:(OI)(CI)F" /grant "Administrators:(OI)(CI)F"

# Then save credentials while running as Admin (SYSTEM will inherit)
# You need to use a different approach - store password in a secure way
```

**Recommended for Lab**: Just add SQLTaskUser to local Administrators group.

### Connection Errors
- Verify SQL Server is running
- Check Windows Firewall settings
- Verify the service account has SQL permissions

### Credential File Errors
```powershell
# Verify credential file exists and is readable
Test-Path "C:\Scripts\SQLMonitoring\sqlcred.xml"

# Test loading credentials (must run as the user who created them)
$cred = Import-Clixml -Path "C:\Scripts\SQLMonitoring\sqlcred.xml"
$cred.UserName
```

### View Recent Events
```powershell
Get-EventLog -LogName Application -Source SQLServerMonitor -Newest 10
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| SqlInstance | localhost | SQL Server instance name |
| EventLogName | Application | Windows Event Log to write to |
| EventSource | SQLServerMonitor | Event Source name |
| EventId | 1000 | Event ID for success (1001 for errors) |
| UseSqlAuthentication | $false | Use SQL Server authentication instead of Windows |
| SqlUsername | - | SQL Server username (optional, for display) |
| CredentialPath | - | Path to encrypted credential file (required for SQL Auth) |

## Functions

| Function | Description |
|----------|-------------|
| `Save-SqlCredential` | Saves SQL credentials to an encrypted file. Run once interactively as the scheduled task user. |

### Save-SqlCredential Usage

```powershell
# Dot-source the script to load the function
. .\Get-SQLServerInfo.ps1

# Save credentials (will prompt for password)
Save-SqlCredential -Path "C:\Scripts\SQLMonitoring\sqlcred.xml" -Username "SQLMonitorReader"
```

**Note**: The credential file is encrypted using Windows DPAPI and can only be decrypted by the same user on the same machine. This is why you must create the credential file while logged in as the scheduled task user.

## License

MIT License - Free to use and modify.
