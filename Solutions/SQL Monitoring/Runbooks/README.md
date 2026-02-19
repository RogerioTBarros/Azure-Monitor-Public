# SQL Server Monitoring Runbook for Azure Automation

This folder contains an Azure Automation runbook designed to run on Hybrid Workers for centralized SQL Server monitoring.

## Overview

This runbook connects from a central Hybrid Worker to multiple SQL Server instances, collects monitoring data (uptime, backup status), and pushes the data directly to Azure Monitor via the Logs Ingestion API.

## Runbook

| File | Description |
|------|-------------|
| [Get-SQLServerInfo-LogsIngestionApi.ps1](Get-SQLServerInfo-LogsIngestionApi.ps1) | Collects SQL Server metrics and pushes to custom Log Analytics table |

## Architecture

```
┌─────────────────┐     ┌───────────────────┐     ┌─────────────────┐
│  SQL Server 1   │────▶│                   │     │                 │
├─────────────────┤     │   Hybrid Worker   │     │   Log Analytics │
│  SQL Server 2   │────▶│   (Runbook)       │────▶│   Workspace     │
├─────────────────┤     │                   │     │                 │
│  SQL Server N   │────▶│ Logs Ingestion    │     │ Custom Table:   │
└─────────────────┘     │ API (Direct)      │     │ SQLServerMonitoring_CL
                        └───────────────────┘     └─────────────────┘
```

## Benefits

- **Proper attribution**: Each record identifies the source SQL Server
- **Near real-time**: Data appears in seconds
- **Clean schema**: Custom table columns, no JSON parsing in KQL
- **Scalable**: Works great for many SQL instances
- **Secure**: Uses Managed Identity for Azure authentication

---

## Prerequisites

1. Azure Automation Account with Hybrid Worker Group
2. System or User-assigned Managed Identity on Automation Account
3. Log Analytics Workspace
4. Data Collection Endpoint (DCE)
5. Data Collection Rule (DCR) for custom logs
6. SQL connectivity from Hybrid Worker (port 1433)
7. **For SQL Authentication**: Azure Key Vault with SQL credentials stored as secrets

### SQL Server Authentication Options

The runbook supports two authentication methods for connecting to SQL Server:

| Option | When to Use | Requirements |
|--------|-------------|-------------|
| **Windows Authentication** | Domain-joined SQL Servers | Hybrid Worker service account has SQL access |
| **SQL Authentication** | Non-domain, mixed environments | Key Vault with SQL credentials |

#### Option A: Windows Authentication

Use this when:
- SQL Servers are domain-joined
- Hybrid Worker is domain-joined
- Hybrid Worker service account has SQL Server permissions

**Pros**: No credential management, Kerberos authentication
**Cons**: Requires domain trust between Hybrid Worker and SQL Servers

#### Option B: SQL Authentication with Key Vault

Use this when:
- SQL Servers are not domain-joined
- Mixed environment (some domain, some workgroup)
- Enhanced credential security required

**Pros**: Works in any network topology, credentials secured in Key Vault
**Cons**: Requires Key Vault setup and Managed Identity permissions

### Setup Steps

#### 1. Enable Managed Identity

1. Go to Azure Portal → Automation Account → Identity
2. Enable **System-assigned** Managed Identity (or add User-assigned)
3. Copy the Object (principal) ID

#### 2. Create Log Analytics Custom Table

In Log Analytics workspace, create the custom table schema:

```bash
# Using Azure CLI
az monitor log-analytics workspace table create \
    --resource-group "MyRG" \
    --workspace-name "MyWorkspace" \
    --name "SQLServerMonitoring_CL" \
    --columns \
        TimeGenerated=datetime \
        CollectorName=string \
        SqlInstance=string \
        ServerName=string \
        SqlVersion=string \
        InstanceStartTime=datetime \
        InstanceUptimeSeconds=int \
        InstanceUptimeMinutes=int \
        InstanceUptimeHours=int \
        InstanceUptimeDays=int \
        DatabaseName=string \
        DatabaseState=string \
        RecoveryModel=string \
        DatabaseCreateDate=datetime \
        LastFullBackupTime=datetime \
        HoursSinceFullBackup=int \
        LastFullBackupStatus=string \
        FullBackupAlertStatus=string \
        LastLogBackupTime=datetime \
        MinutesSinceLogBackup=int
```

#### 3. (For SQL Auth) Create Key Vault and Store Credentials

If using SQL Authentication, create a Key Vault and store the SQL credentials:

```bash
# Create Key Vault
az keyvault create \
    --resource-group "MyRG" \
    --name "sql-monitoring-kv" \
    --location "eastus" \
    --enable-rbac-authorization true

# Store SQL username
az keyvault secret set \
    --vault-name "sql-monitoring-kv" \
    --name "SqlMonitorUsername" \
    --value "your-sql-username"

# Store SQL password
az keyvault secret set \
    --vault-name "sql-monitoring-kv" \
    --name "SqlMonitorPassword" \
    --value "your-sql-password"
```

Grant Managed Identity access to Key Vault secrets:

```bash
# Get the Automation Account's Managed Identity Object ID
objectId=$(az automation account show \
    --resource-group "MyRG" \
    --name "MyAutomation" \
    --query "identity.principalId" -o tsv)

# Get Key Vault resource ID
kvId=$(az keyvault show \
    --resource-group "MyRG" \
    --name "sql-monitoring-kv" \
    --query "id" -o tsv)

# Assign "Key Vault Secrets User" role
az role assignment create \
    --assignee "$objectId" \
    --role "Key Vault Secrets User" \
    --scope "$kvId"
```

#### 4. Create Data Collection Endpoint (DCE)

```bash
az monitor data-collection endpoint create \
    --resource-group "MyRG" \
    --name "sql-monitoring-dce" \
    --location "eastus" \
    --public-network-access "Enabled"
```

Get the DCE Logs Ingestion URI:
```bash
az monitor data-collection endpoint show \
    --resource-group "MyRG" \
    --name "sql-monitoring-dce" \
    --query "logsIngestion.endpoint" -o tsv
```

#### 5. Create Data Collection Rule (DCR)

Create a file `dcr-sql-monitoring.json`:

```json
{
    "location": "eastus",
    "properties": {
        "dataCollectionEndpointId": "/subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.Insights/dataCollectionEndpoints/sql-monitoring-dce",
        "streamDeclarations": {
            "Custom-SQLServerMonitoring_CL": {
                "columns": [
                    { "name": "TimeGenerated", "type": "datetime" },
                    { "name": "CollectorName", "type": "string" },
                    { "name": "SqlInstance", "type": "string" },
                    { "name": "ServerName", "type": "string" },
                    { "name": "SqlVersion", "type": "string" },
                    { "name": "InstanceStartTime", "type": "datetime" },
                    { "name": "InstanceUptimeSeconds", "type": "int" },
                    { "name": "InstanceUptimeMinutes", "type": "int" },
                    { "name": "InstanceUptimeHours", "type": "int" },
                    { "name": "InstanceUptimeDays", "type": "int" },
                    { "name": "DatabaseName", "type": "string" },
                    { "name": "DatabaseState", "type": "string" },
                    { "name": "RecoveryModel", "type": "string" },
                    { "name": "DatabaseCreateDate", "type": "datetime" },
                    { "name": "LastFullBackupTime", "type": "datetime" },
                    { "name": "HoursSinceFullBackup", "type": "int" },
                    { "name": "LastFullBackupStatus", "type": "string" },
                    { "name": "FullBackupAlertStatus", "type": "string" },
                    { "name": "LastLogBackupTime", "type": "datetime" },
                    { "name": "MinutesSinceLogBackup", "type": "int" }
                ]
            }
        },
        "destinations": {
            "logAnalytics": [
                {
                    "workspaceResourceId": "/subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.OperationalInsights/workspaces/<WORKSPACE>",
                    "name": "myWorkspace"
                }
            ]
        },
        "dataFlows": [
            {
                "streams": ["Custom-SQLServerMonitoring_CL"],
                "destinations": ["myWorkspace"],
                "transformKql": "source",
                "outputStream": "Custom-SQLServerMonitoring_CL"
            }
        ]
    }
}
```

Create the DCR:
```bash
az monitor data-collection rule create \
    --resource-group "MyRG" \
    --name "dcr-sql-monitoring" \
    --location "eastus" \
    --rule-file "dcr-sql-monitoring.json"
```

Get the DCR immutable ID:
```bash
az monitor data-collection rule show \
    --resource-group "MyRG" \
    --name "dcr-sql-monitoring" \
    --query "immutableId" -o tsv
```

#### 6. Assign Permissions to Managed Identity

The Managed Identity needs "Monitoring Metrics Publisher" role on the DCR:

```bash
# Get the Automation Account's Managed Identity Object ID
objectId=$(az automation account show \
    --resource-group "MyRG" \
    --name "MyAutomation" \
    --query "identity.principalId" -o tsv)

# Get the DCR resource ID
dcrId=$(az monitor data-collection rule show \
    --resource-group "MyRG" \
    --name "dcr-sql-monitoring" \
    --query "id" -o tsv)

# Assign role
az role assignment create \
    --assignee "$objectId" \
    --role "Monitoring Metrics Publisher" \
    --scope "$dcrId"
```

#### 7. Import and Configure Runbook

```bash
# Import the runbook
az automation runbook create \
    --resource-group "MyRG" \
    --automation-account-name "MyAutomation" \
    --name "Get-SQLServerInfo-LogsIngestionApi" \
    --type "PowerShell"

# Upload the runbook content
az automation runbook replace-content \
    --resource-group "MyRG" \
    --automation-account-name "MyAutomation" \
    --name "Get-SQLServerInfo-LogsIngestionApi" \
    --content @Get-SQLServerInfo-LogsIngestionApi.ps1

# Publish the runbook
az automation runbook publish \
    --resource-group "MyRG" \
    --automation-account-name "MyAutomation" \
    --name "Get-SQLServerInfo-LogsIngestionApi"
```

#### 8. Create Schedule with Parameters

```bash
# Create a schedule (every 5 minutes)
# Calculate start time 5 minutes from now in ISO 8601 format
startTime=$(date -u -d "+5 minutes" +"%Y-%m-%dT%H:%M:%SZ")

az automation schedule create \
    --resource-group "MyRG" \
    --automation-account-name "MyAutomation" \
    --name "SQLMonitoring-LogsAPI-5Min" \
    --start-time "$startTime" \
    --frequency "Minute" \
    --interval 5
```

**Option A: Windows Authentication**

```bash
# Link the runbook to the schedule with parameters
az automation job-schedule create \
    --resource-group "MyRG" \
    --automation-account-name "MyAutomation" \
    --runbook-name "Get-SQLServerInfo-LogsIngestionApi" \
    --schedule-name "SQLMonitoring-LogsAPI-5Min" \
    --run-on "MyHybridWorkerGroup" \
    --parameters '{"SqlInstances":"SQLServer1,SQLServer2\\Instance1,10.0.0.5","SqlAuthenticationType":"Windows","DceEndpoint":"https://sql-monitoring-dce-xxxx.eastus-1.ingest.monitor.azure.com","DcrImmutableId":"dcr-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","StreamName":"Custom-SQLServerMonitoring_CL"}'
```

**Option B: SQL Authentication with Key Vault**

```bash
# Link the runbook to the schedule with parameters (SQL Auth)
az automation job-schedule create \
    --resource-group "MyRG" \
    --automation-account-name "MyAutomation" \
    --runbook-name "Get-SQLServerInfo-LogsIngestionApi" \
    --schedule-name "SQLMonitoring-LogsAPI-5Min" \
    --run-on "MyHybridWorkerGroup" \
    --parameters '{"SqlInstances":"SQLServer1,SQLServer2\\Instance1,10.0.0.5","SqlAuthenticationType":"SQL","KeyVaultName":"sql-monitoring-kv","SqlUsernameSecretName":"SqlMonitorUsername","SqlPasswordSecretName":"SqlMonitorPassword","DceEndpoint":"https://sql-monitoring-dce-xxxx.eastus-1.ingest.monitor.azure.com","DcrImmutableId":"dcr-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","StreamName":"Custom-SQLServerMonitoring_CL"}'
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `SqlInstances` | Yes | - | Array of SQL Server instance names |
| `SqlAuthenticationType` | No | Windows | `Windows` or `SQL` |
| `KeyVaultName` | For SQL Auth | - | Key Vault name containing SQL credentials |
| `SqlUsernameSecretName` | No | SqlMonitorUsername | Secret name for SQL username |
| `SqlPasswordSecretName` | No | SqlMonitorPassword | Secret name for SQL password |
| `DceEndpoint` | Yes | - | Data Collection Endpoint URI |
| `DcrImmutableId` | Yes | - | DCR immutable ID |
| `StreamName` | No | Custom-SQLServerMonitoring_CL | Stream name in DCR |
| `ManagedIdentityClientId` | No | - | Client ID for User-assigned MI |

### KQL Queries

The custom table has a clean schema - no JSON parsing needed!

```kql
// Overview of all SQL Servers
SQLServerMonitoring_CL
| summarize 
    LastSeen = max(TimeGenerated),
    DatabaseCount = dcount(DatabaseName),
    InstanceUptimeDays = max(InstanceUptimeDays)
    by SqlInstance, ServerName
| order by LastSeen desc

// Databases with backup alerts
SQLServerMonitoring_CL
| where TimeGenerated > ago(1h)
| where FullBackupAlertStatus in ("Warning", "Critical", "Never")
| project TimeGenerated, SqlInstance, DatabaseName, 
          FullBackupAlertStatus, HoursSinceFullBackup, RecoveryModel
| order by FullBackupAlertStatus asc, HoursSinceFullBackup desc

// Instance uptime across all servers
SQLServerMonitoring_CL
| where TimeGenerated > ago(1h)
| summarize arg_max(TimeGenerated, *) by SqlInstance
| project SqlInstance, ServerName, InstanceStartTime, 
          InstanceUptimeDays, InstanceUptimeHours
| order by InstanceUptimeDays desc

// Database uptime in minutes
SQLServerMonitoring_CL
| where TimeGenerated > ago(1h)
| summarize arg_max(TimeGenerated, *) by SqlInstance, DatabaseName
| extend UptimeMinutes = InstanceUptimeMinutes
| project TimeGenerated, SqlInstance, DatabaseName, UptimeMinutes

// Backup SLA compliance (databases backed up within 24 hours)
SQLServerMonitoring_CL
| where TimeGenerated > ago(1h)
| where DatabaseName != "_ERROR"
| summarize arg_max(TimeGenerated, *) by SqlInstance, DatabaseName
| summarize 
    TotalDatabases = count(),
    CompliantDatabases = countif(HoursSinceFullBackup <= 24 and HoursSinceFullBackup >= 0),
    NonCompliant = countif(HoursSinceFullBackup > 24 or HoursSinceFullBackup < 0)
    by SqlInstance
| extend CompliancePercent = round(100.0 * CompliantDatabases / TotalDatabases, 2)
```

---

## Troubleshooting

### Connection Errors

1. **Network connectivity**: Ensure Hybrid Worker can reach SQL Servers on port 1433
2. **Firewall rules**: Check Windows Firewall and SQL Server firewall settings
3. **SQL Browser**: If using named instances, ensure SQL Browser is running
4. **Authentication**: Verify credentials and SQL login permissions

### Key Vault Errors (SQL Authentication)

1. **401 Unauthorized**: Managed Identity not enabled or not granted access to Key Vault
2. **403 Forbidden**: Managed Identity doesn't have "Key Vault Secrets User" role
3. **SecretNotFound**: Check secret names match parameters (`SqlUsernameSecretName`, `SqlPasswordSecretName`)
4. **Network error**: If using Private Endpoints, ensure Hybrid Worker can reach Key Vault

### Logs Ingestion API Errors

1. **401 Unauthorized**: Check Managed Identity is enabled and has role assignment
2. **403 Forbidden**: Verify "Monitoring Metrics Publisher" role on DCR
3. **404 Not Found**: Check DCE endpoint and DCR immutable ID are correct
4. **Schema mismatch**: Ensure data matches the stream declaration in DCR

---

## Security Best Practices

1. **Use Managed Identity** for all Azure service authentication
2. **Store SQL credentials in Key Vault** (not in Automation Credentials or scripts)
3. **Enable Key Vault RBAC** for granular access control
4. **Principle of least privilege**: SQL login only needs:
   - `VIEW SERVER STATE` permission
   - `db_datareader` on `msdb` database
   - `CONNECT` on each target database
5. **Network segmentation**: 
   - Use Private Endpoints for Key Vault
   - Use Private Endpoints for DCE
   - Restrict Hybrid Worker network access
6. **Audit logging**:
   - Enable diagnostic settings on Automation Account
   - Enable Key Vault audit logging
7. **Rotate SQL credentials** regularly using Key Vault secret rotation
8. **Use Windows Authentication** when possible (eliminates credential management)

---

## Related Files

- [../Get-SQLServerInfo.ps1](../Get-SQLServerInfo.ps1) - Original scheduled task script
- [../README.md](../README.md) - Main documentation
- [../Workbooks/SQLServerMonitoring.workbook](../Workbooks/SQLServerMonitoring.workbook) - Azure Workbook for visualization

---

## Azure Workbook Deployment

An Azure Workbook is provided to visualize the SQL Server monitoring data collected by this automation.

### Workbook Features

| Tab | Description |
|-----|-------------|
| **📊 Summary** | Overview metrics: Total instances, databases, backup alerts, compliance percentage. Pie charts for backup status and recovery model. Instance uptime table. |
| **🖥️ Instances** | Detailed view of SQL Server instances with online/offline status, version, database count, uptime, and last seen time. Uptime trend chart. |
| **🗄️ Databases** | All databases with state, recovery model, creation date, backup status, and alert indicators. Database count by instance chart. |
| **💾 Backups** | Backup compliance by instance, databases requiring attention, full backup details, and log backup status for FULL recovery databases. |

### Parameters

| Parameter | Description |
|-----------|-------------|
| **Subscription** | Azure subscription containing the Log Analytics Workspace |
| **Log Analytics Workspace** | The workspace where `SQLServerMonitoring_CL` data is stored |
| **Time Range** | Time period for queries (default: Last 24 hours) |
| **SQL Instance** | Filter by specific SQL Server instances (multi-select) |
| **Database** | Filter by specific databases (multi-select) |

### Deployment Options

#### Option 1: Deploy via Azure Portal (Manual)

1. Navigate to **Azure Portal** → **Monitor** → **Workbooks**
2. Click **+ New**
3. Click the **</>** (Advanced Editor) button in the toolbar
4. Select **Gallery Template** tab
5. Copy the entire content of [`SQLServerMonitoring.workbook`](../Workbooks/SQLServerMonitoring.workbook)
6. Paste into the editor, replacing all existing content
7. Click **Apply**
8. Select your **Subscription** and **Log Analytics Workspace** from the parameter dropdowns
9. Click **Save** → Choose a name, resource group, and location
10. Optionally, click **Save to gallery** to add to your workbook gallery

#### Option 2: Deploy via Azure CLI

```bash
# Variables
resourceGroup="MyResourceGroup"
workbookName="SQL Server Monitoring"
location="eastus"
workbookFile="SQLServerMonitoring.workbook"

# Get the workbook content
workbookContent=$(cat "$workbookFile")

# Create the workbook resource
az monitor workbook create \
    --resource-group "$resourceGroup" \
    --name "$workbookName" \
    --location "$location" \
    --kind "shared" \
    --category "workbook" \
    --display-name "$workbookName" \
    --serialized-data "$workbookContent"
```

#### Option 3: Deploy via PowerShell

```powershell
# Variables
$resourceGroup = "MyResourceGroup"
$workbookName = "SQL Server Monitoring"
$location = "eastus"
$workbookFile = "SQLServerMonitoring.workbook"

# Read the workbook content
$workbookContent = Get-Content -Path $workbookFile -Raw

# Generate a new GUID for the workbook resource
$workbookId = [guid]::NewGuid().ToString()

# Create the workbook using ARM
$workbookResource = @{
    "id" = "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$resourceGroup/providers/Microsoft.Insights/workbooks/$workbookId"
    "name" = $workbookId
    "type" = "Microsoft.Insights/workbooks"
    "location" = $location
    "kind" = "shared"
    "properties" = @{
        "displayName" = $workbookName
        "serializedData" = $workbookContent
        "category" = "workbook"
    }
}

# Deploy using New-AzResource
New-AzResource -ResourceGroupName $resourceGroup `
    -ResourceType "Microsoft.Insights/workbooks" `
    -ResourceName $workbookId `
    -Location $location `
    -Properties $workbookResource.properties `
    -Kind "shared" `
    -Force
```

#### Option 4: Deploy via ARM Template

Create a file `deploy-workbook.json`:

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "workbookName": {
            "type": "string",
            "defaultValue": "SQL Server Monitoring",
            "metadata": {
                "description": "The name of the workbook"
            }
        },
        "location": {
            "type": "string",
            "defaultValue": "[resourceGroup().location]",
            "metadata": {
                "description": "Location for the workbook"
            }
        }
    },
    "variables": {
        "workbookId": "[guid(resourceGroup().id, parameters('workbookName'))]"
    },
    "resources": [
        {
            "type": "Microsoft.Insights/workbooks",
            "apiVersion": "2022-04-01",
            "name": "[variables('workbookId')]",
            "location": "[parameters('location')]",
            "kind": "shared",
            "properties": {
                "displayName": "[parameters('workbookName')]",
                "serializedData": "[concat('{\"version\":\"Notebook/1.0\",\"items\":[{\"type\":1,\"content\":{\"json\":\"# SQL Server Monitoring Dashboard\\n\\nThis workbook displays SQL Server monitoring data...\"},...}]}')]",
                "category": "workbook"
            }
        }
    ],
    "outputs": {
        "workbookId": {
            "type": "string",
            "value": "[variables('workbookId')]"
        }
    }
}
```

Deploy:
```bash
az deployment group create \
    --resource-group "MyResourceGroup" \
    --template-file "deploy-workbook.json" \
    --parameters workbookName="SQL Server Monitoring"
```

### Workbook Screenshots

After deployment, the workbook provides:

- **Summary Tab**: Quick overview with KPI tiles and charts
- **Instances Tab**: SQL Server instance health and uptime tracking
- **Databases Tab**: Database inventory with state and backup info
- **Backups Tab**: Detailed backup compliance monitoring

### Customization

To customize the workbook:

1. Open the workbook in Azure Portal
2. Click **Edit** in the toolbar
3. Modify queries, visualizations, or add new items
4. Click **Done Editing** → **Save**

Common customizations:
- Adjust backup SLA thresholds (currently 24h for OK, 48h for Warning)
- Add additional metrics or charts
- Customize colors and formatting
- Add links to related Azure resources
