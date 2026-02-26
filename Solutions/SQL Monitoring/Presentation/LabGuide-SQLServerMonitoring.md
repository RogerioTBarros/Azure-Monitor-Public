# SQL Server Monitoring Solution — Lab Deployment Guide

> **Audience**: Customers who want to deploy the SQL Server Monitoring solution in their own Azure subscription.  
> **Estimated time**: 60–90 minutes  
> **Skill level**: Intermediate (basic Azure Portal experience required)

---

## Table of Contents

1. [Solution Overview](#1-solution-overview)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Lab Environment Setup](#4-lab-environment-setup)
5. [Step 1 — Deploy Infrastructure (ARM Template)](#step-1--deploy-infrastructure-arm-template)
6. [Step 2 — Deploy Data Collection Components (ARM Template)](#step-2--deploy-data-collection-components-arm-template)
7. [Step 3 — Configure RBAC Permissions](#step-3--configure-rbac-permissions)
8. [Step 4 — Prepare the SQL Server(s)](#step-4--prepare-the-sql-servers)
9. [Step 5 — Configure the Hybrid Worker](#step-5--configure-the-hybrid-worker)
10. [Step 6 — Import and Configure the Runbook](#step-6--import-and-configure-the-runbook)
11. [Step 7 — Deploy the Workbook (ARM Template)](#step-7--deploy-the-workbook-arm-template)
12. [Step 8 — Test and Validate](#step-8--test-and-validate)
13. [Troubleshooting](#troubleshooting)
14. [FAQ](#faq)

---

## 1. Solution Overview

This solution provides centralized monitoring of SQL Server instances (on-premises, IaaS VMs, or Azure Arc-enabled servers) using native Azure Monitor components. It collects:

| Metric | Description |
|--------|-------------|
| **Instance Uptime** | Start time, uptime in seconds/minutes/hours/days |
| **Database Inventory** | Name, state, recovery model, create date |
| **Backup Status** | Last full/log backup, hours since backup, alert status |
| **Connection Errors** | Records connection failures for alerting |

Data is sent directly to a **custom Log Analytics table** (`SQLServerMonitoring_CL`) via the **Logs Ingestion API** — no agents installed on SQL Servers required.

### Key Benefits

- **Agentless on SQL Servers** — only the Hybrid Worker VM needs the Azure Automation extension
- **Custom schema** — clean 20-column table, no JSON parsing in KQL
- **Secure** — Managed Identity authentication, no stored passwords in runbooks
- **Scalable** — monitor hundreds of SQL instances from a single Hybrid Worker
- **Visualized** — pre-built Azure Monitor Workbook with 4 dashboard tabs

---

## 2. Architecture

```
┌─────────────────────┐                    ┌──────────────────────────┐
│  SQL Server 1       │──── TCP 1433 ────▶│                          │
│  SQL Server 2       │──── TCP 1433 ────▶│  Hybrid Worker VM        │
│  SQL Server N       │──── TCP 1433 ────▶│  (Arc-enabled server)    │
│                     │                    │                          │
│  On-Prem / IaaS     │                    │  ┌──────────────────┐   │
└─────────────────────┘                    │  │ PowerShell 7.2   │   │
                                           │  │ Runbook          │   │
                                           │  └──────┬───────────┘   │
                                           └─────────┼───────────────┘
                                                      │
                                                      │ HTTPS POST (Managed Identity)
                                                      ▼
                              ┌─────────────────────────────────────────┐
                              │         Azure Cloud                     │
                              │                                         │
                              │  ┌─────────────┐   ┌──────────────┐   │
                              │  │ Automation   │   │  Key Vault   │   │
                              │  │ Account      │   │  (optional)  │   │
                              │  │ + Schedule   │   │  SQL creds   │   │
                              │  └─────────────┘   └──────────────┘   │
                              │                                         │
                              │  ┌─────────────┐   ┌──────────────┐   │
                              │  │ DCE          │──▶│  DCR         │   │
                              │  │ (Endpoint)   │   │  (Rule)      │   │
                              │  └─────────────┘   └──────┬───────┘   │
                              │                            │           │
                              │                            ▼           │
                              │  ┌─────────────┐   ┌──────────────┐   │
                              │  │ Log Analytics│◀──│ Custom Table │   │
                              │  │ Workspace    │   │ SQLServer    │   │
                              │  └──────┬──────┘   │ Monitoring_CL│   │
                              │         │          └──────────────┘   │
                              │         ▼                              │
                              │  ┌──────────────┐                     │
                              │  │ Azure Monitor │                     │
                              │  │ Workbook      │                     │
                              │  │ (4 tabs)      │                     │
                              │  └──────────────┘                     │
                              └─────────────────────────────────────────┘
```

### Data Flow

1. **Azure Automation** triggers the runbook on a schedule (e.g., every hour)
2. The **Hybrid Worker** executes the runbook locally on the Arc-enabled VM
3. The runbook connects to each SQL Server via **TCP 1433** (Windows or SQL Authentication)
4. Collected metrics are **POST**ed to the **Data Collection Endpoint** using the Logs Ingestion API
5. The **Data Collection Rule** routes data to the `SQLServerMonitoring_CL` custom table
6. The **Azure Monitor Workbook** visualizes the data via KQL queries

---

## 3. Prerequisites

### Azure Resources You'll Need

| Resource | Purpose | Notes |
|----------|---------|-------|
| Azure Subscription | Host all resources | Contributor access required |
| Resource Group | Container for all resources | Create one or use existing |
| Log Analytics Workspace | Store monitoring data | Use existing or create via template |
| Azure Automation Account | Run the collection runbook | Use existing or create via template |
| VM / Server (Hybrid Worker) | Execute runbook on-premises | Windows Server, Azure Arc-enabled |
| Key Vault (optional) | Store SQL credentials | Use existing or create via template (SQL Auth only) |

### Network Requirements

| Source | Destination | Port | Protocol | Purpose |
|--------|-------------|------|----------|---------|
| Hybrid Worker VM | SQL Server(s) | 1433 | TCP | SQL queries |
| Hybrid Worker VM | *.azure-automation.net | 443 | HTTPS | Automation service |
| Hybrid Worker VM | *.monitor.azure.com | 443 | HTTPS | Logs Ingestion API |
| Hybrid Worker VM | *.vault.azure.net | 443 | HTTPS | Key Vault (SQL Auth only) |
| Hybrid Worker VM | login.microsoftonline.com | 443 | HTTPS | Azure AD authentication |

### Software Requirements on Hybrid Worker VM

- Windows Server 2016 or later
- .NET Framework 4.7.2 or later
- Azure Connected Machine Agent (for Arc-enabled servers) — OR — Azure VM with Hybrid Worker extension
- PowerShell 7.2+ (installed automatically by the Hybrid Worker extension)

---

## 4. Lab Environment Setup

### Option A: Use Existing SQL Servers

If you already have SQL Server instances in your environment, simply ensure the Hybrid Worker VM has network connectivity to them on port 1433.

### Option B: Create a Lab SQL Server VM in Azure

1. Go to **Azure Portal → Create a resource → SQL Server on Azure VM**
2. Choose:
   - **Image**: Free SQL Server Developer on Windows Server 2022
   - **Size**: Standard_B2s (sufficient for lab)
   - **Authentication**: Set an admin password
3. In **SQL Server settings**:
   - **SQL connectivity**: Private (within Virtual Network)
   - **Port**: 1433
   - **SQL Authentication**: Enable
4. Deploy and note the **private IP address**

### Option C: Use Azure Arc-enabled SQL Server

If you have on-premises SQL Servers, connect them to Azure Arc:
1. Go to **Azure Portal → Azure Arc → SQL Servers → Add**
2. Follow the wizard to install the Arc agent on your SQL Server machine

---

## 5. Deployment Steps

### Step 1 — Deploy Infrastructure (ARM Template)

This template creates the foundational Azure resources.

1. Navigate to **Azure Portal → Deploy a custom template**
2. Click **"Build your own template in the editor"**
3. Load the file: `CustomerTemplates/arm-template-infrastructure.json`
4. Click **Save**, then fill in the parameters:

| Parameter | Description | Example |
|-----------|-------------|---------|
| `automationAccountName` | Name of the Automation Account (existing or new) | `mycompany-sql-monitoring-aa` |
| `createAutomationAccount` | `true` to create new, `false` to use existing | `false` |
| `automationAccountResourceGroup` | Resource group of existing Automation Account | `rg-shared-services` |
| `logAnalyticsWorkspaceName` | Name of the Log Analytics Workspace (existing or new) | `mycompany-sql-monitoring-law` |
| `createLogAnalyticsWorkspace` | `true` to create new, `false` to use existing | `true` |
| `logAnalyticsWorkspaceResourceGroup` | Resource group of existing workspace | `rg-monitoring` |
| `location` | Azure region for new resources | `eastus` |
| `enableKeyVault` | Set to `true` if using SQL Authentication | `false` |
| `createKeyVault` | `true` to create new, `false` to use existing | `false` |
| `keyVaultName` | Name of the Key Vault (SQL Auth scenarios) | `mycompany-sqlmon-kv` |
| `keyVaultResourceGroup` | Resource group of existing Key Vault | `rg-security` |

5. Click **Review + create → Create**
6. Wait for deployment to complete (~2-3 minutes)

> **Important**: The custom table `SQLServerMonitoring_CL` is always created/updated, even when using an existing workspace. The deploying user needs Contributor access on the workspace's resource group if it differs from the deployment resource group.

> **After deployment**, note the values in the **Outputs** tab:
> - `automationAccountPrincipalId`
> - `automationAccountResourceGroup`
> - `logAnalyticsWorkspaceId`
> - `logAnalyticsWorkspaceResourceGroup`
> - `keyVaultName` (if enabled)

---

### Step 2 — Deploy Data Collection Components (ARM Template)

This template creates the DCE, DCR, and custom Log Analytics table.

1. Navigate to **Azure Portal → Deploy a custom template**
2. Click **"Build your own template in the editor"**
3. Load the file: `CustomerTemplates/arm-template-data-collection.json`
4. Click **Save**, then fill in the parameters:

| Parameter | Description | Example |
|-----------|-------------|---------|
| `logAnalyticsWorkspaceName` | Name of workspace from Step 1 | `mycompany-sql-monitoring-law` |
| `dataCollectionEndpointName` | Name for the DCE | `sql-monitoring-dce` |
| `dataCollectionRuleName` | Name for the DCR | `dcr-sql-monitoring` |
| `location` | Must match the workspace region | `eastus` |

5. Click **Review + create → Create**
6. Wait for deployment (~1-2 minutes)

> **After deployment**, note the values in the **Outputs** tab:
> - `dceEndpoint` — the Logs Ingestion API endpoint URL
> - `dcrImmutableId` — the DCR immutable identifier (starts with `dcr-`)
> - `dcrResourceId` — the full resource ID (needed for RBAC)

---

### Step 3 — Configure RBAC Permissions

The Automation Account's Managed Identity needs permission to send data to the DCR.

1. Go to **Azure Portal → Data Collection Rules → dcr-sql-monitoring**
2. Click **Access control (IAM) → Add → Add role assignment**
3. Role: **Monitoring Metrics Publisher**
4. Members → **Managed identity** → Select → Choose your **Automation Account**
5. Click **Review + assign**

**If using SQL Authentication** (Key Vault):
1. Go to **Azure Portal → Key Vaults → your-kv**
2. Click **Access control (IAM) → Add → Add role assignment**
3. Role: **Key Vault Secrets User**
4. Members → **Managed identity** → Select → Choose your **Automation Account**
5. Click **Review + assign**

Then store your SQL credentials:
1. Go to **Key Vault → Secrets → Generate/Import**
2. Create secret `SqlMonitorUsername` with your SQL login username
3. Create secret `SqlMonitorPassword` with your SQL login password

---

### Step 4 — Prepare the SQL Server(s)

#### For Windows Authentication
Ensure the Hybrid Worker VM's service account (or computer account) has a SQL Server login with at least these permissions:
- `VIEW SERVER STATE`
- `VIEW ANY DATABASE`
- Read access to `msdb.dbo.backupset`

```sql
-- Run on each SQL Server
USE [master];
CREATE LOGIN [YOURDOMAIN\HybridWorkerVM$] FROM WINDOWS;
GRANT VIEW SERVER STATE TO [YOURDOMAIN\HybridWorkerVM$];
GRANT VIEW ANY DATABASE TO [YOURDOMAIN\HybridWorkerVM$];
GO
USE [msdb];
CREATE USER [YOURDOMAIN\HybridWorkerVM$] FOR LOGIN [YOURDOMAIN\HybridWorkerVM$];
EXEC sp_addrolemember 'db_datareader', 'YOURDOMAIN\HybridWorkerVM$';
GO
```

#### For SQL Authentication
Create a SQL login on each SQL Server:

```sql
-- Run on each SQL Server
USE [master];
CREATE LOGIN [sqlmonitor] WITH PASSWORD = 'YourStrongPassword!';
GRANT VIEW SERVER STATE TO [sqlmonitor];
GRANT VIEW ANY DATABASE TO [sqlmonitor];
GO
USE [msdb];
CREATE USER [sqlmonitor] FOR LOGIN [sqlmonitor];
EXEC sp_addrolemember 'db_datareader', 'sqlmonitor';
GO
```

#### Test connectivity
From the Hybrid Worker VM, verify SQL connectivity:
```powershell
# Test TCP connectivity
Test-NetConnection -ComputerName "YOUR_SQL_SERVER_IP" -Port 1433

# Test SQL connection (Windows Auth)
$conn = New-Object System.Data.SqlClient.SqlConnection("Server=YOUR_SQL_SERVER_IP;Integrated Security=True;TrustServerCertificate=True;")
$conn.Open()
Write-Host "Connected: $($conn.State)"
$conn.Close()
```

---

### Step 5 — Configure the Hybrid Worker

#### If using Azure Arc-enabled server:

1. Go to **Azure Portal → Azure Automation → Your Account → Hybrid Worker Groups**
2. Click **+ Create hybrid worker group**
3. Name: `SQLMonitoringWorkers` (or your preference)
4. Click **Add hybrid workers → Add machines**
5. Select your Arc-enabled server
6. Click **Add → Review + create → Create**

The Hybrid Worker extension will be installed automatically on the Arc VM.

#### If using Azure VM:

1. Go to **Azure Portal → Azure Automation → Your Account → Hybrid Worker Groups**
2. Click **+ Create hybrid worker group**
3. Name: `SQLMonitoringWorkers`
4. Click **Add hybrid workers → Add machines**
5. Select your Azure VM
6. Click **Add → Review + create → Create**

> **Verification**: After ~5 minutes, check that the worker shows "Connected" status in the Hybrid Worker Group.

---

### Step 5.5 — Create the SQL Instances Variable

The runbook reads the list of SQL Server instances from an **Automation Account variable**, making it easy to add or change instances without modifying the schedule.

1. Go to **Azure Portal → Azure Automation → Your Account → Variables**
2. Click **+ Add a variable**
3. Fill in:
   - **Name**: `SqlInstances`
   - **Type**: String
   - **Value**: A JSON array of your SQL Server addresses:
     ```json
     ["Server1", "Server2\\Instance1", "10.0.0.5"]
     ```
   - **Encrypted**: No
4. Click **Create**

> **Tip**: When SQL Server IPs or hostnames change, simply update this variable value — no need to delete and recreate the schedule link.

---

### Step 6 — Import and Configure the Runbook

#### 6a. Import the Runbook

1. Go to **Azure Portal → Azure Automation → Your Account → Runbooks**
2. Click **+ Create a runbook**
   - Name: `Get-SQLServerInfo-LogsIngestionApi`
   - Runbook type: **PowerShell**
   - Runtime version: **7.2**
3. Click **Create**
4. In the editor, paste the content from `CustomerTemplates/Get-SQLServerInfo-LogsIngestionApi.ps1`
5. Click **Save → Publish → Yes**

#### 6b. Create a Schedule

1. Go to **Azure Automation → Your Account → Schedules**
2. Click **+ Add a schedule**
   - Name: `SQLMonitoring-Hourly`
   - Starts: Set to a time 10 minutes from now
   - Recurrence: **Recurring → Every 1 Hour**
   - Set expiration: No
3. Click **Create**

#### 6c. Link Runbook to Schedule

1. Go back to **Runbooks → Get-SQLServerInfo-LogsIngestionApi → Schedules**
2. Click **+ Add a schedule → Link a schedule → SQLMonitoring-Hourly**
3. Click **OK**
4. Configure **Parameters**:

| Parameter | Value |
|-----------|-------|
| `SqlAuthenticationType` | `Windows` or `SQL` |
| `KeyVaultName` | Your Key Vault name (only if SQL Auth) |
| `SqlUsernameSecretName` | `SqlMonitorUsername` (only if SQL Auth) |
| `SqlPasswordSecretName` | `SqlMonitorPassword` (only if SQL Auth) |
| `DceEndpoint` | The DCE endpoint from Step 2 outputs |
| `DcrImmutableId` | The DCR immutable ID from Step 2 outputs |
| `StreamName` | `Custom-SQLServerMonitoring_CL` |
| `ManagedIdentityClientId` | Leave empty for System MI |

> **Note**: `SqlInstances` is **not** listed here — the runbook reads it automatically from the Automation Account variable created in Step 5.5.

5. Run on: Select **Hybrid Worker** → Choose `SQLMonitoringWorkers`
6. Click **OK**

#### 6d. Test Run

1. Go to **Runbooks → Get-SQLServerInfo-LogsIngestionApi**
2. Click **Start**
3. Select **Run on: Hybrid Worker → SQLMonitoringWorkers**
4. Fill in the same parameters as in Step 6c (SqlInstances will be read from the variable automatically)
5. Click **OK**
6. Wait for the job to complete (usually 30-60 seconds)
7. Check the **Output** tab — you should see "Successfully sent X record(s) to Azure Monitor"

---

### Step 7 — Deploy the Workbook (ARM Template)

1. Navigate to **Azure Portal → Deploy a custom template**
2. Click **"Build your own template in the editor"**
3. Load the file: `CustomerTemplates/arm-template-workbook.json`
4. Click **Save**, then fill in the parameters:

| Parameter | Description | Example |
|-----------|-------------|---------|
| `workbookDisplayName` | Display name for the workbook | `SQL Server Monitoring Dashboard` |
| `location` | Azure region (match workspace region) | `eastus` |

5. Click **Review + create → Create**

After deployment:
1. Go to **Azure Portal → Monitor → Workbooks**
2. Find **"SQL Server Monitoring Dashboard"**
3. Open it and select your **Subscription**, **Workspace**, and **Time Range**

---

### Step 8 — Test and Validate

#### Verify Data Collection

Wait 5-10 minutes after the test run, then:

1. Go to **Log Analytics workspace → Logs**
2. Run this query:

```kql
SQLServerMonitoring_CL
| where TimeGenerated > ago(1h)
| project TimeGenerated, SqlInstance, DatabaseName, DatabaseState, RecoveryModel
| order by TimeGenerated desc
```

You should see rows with your SQL Server data.

#### Verify Workbook

1. Go to **Azure Monitor → Workbooks**
2. Open "SQL Server Monitoring Dashboard"
3. Check all 4 tabs:
   - **Summary**: Tile counts, pie charts for backup status and recovery models
   - **Instances**: Uptime, version, database count per instance
   - **Databases**: Database state, recovery model, create date
   - **Backups**: Full backup status, hours since backup, log backups

---

## Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| Job status "Suspended" or "Failed" | Parameter or permissions error | Check job output/errors in Automation Account |
| "Failed to get access token" | Managed Identity not enabled or no RBAC | Enable MI on Automation Account, assign Monitoring Metrics Publisher role on DCR |
| "Login failed for user" | SQL login not configured | Create the SQL login on target servers (see Step 4) |
| "A network-related error" | Firewall or DNS | Test `Test-NetConnection -ComputerName <IP> -Port 1433` from Hybrid Worker |
| Workbook shows no data | Ingestion delay or wrong workspace | Wait 5-10 minutes; verify the workspace parameter in workbook matches |
| "NT AUTHORITY\ANONYMOUS LOGON" | Kerberos issue with Windows Auth cross-domain/workgroup | Use SQL Authentication instead, or configure Kerberos delegation |
| Worker shows "Disconnected" | Extension or agent issue | Restart the Azure Connected Machine Agent service |
| Empty columns in data | Table schema missing columns | Re-run the data collection ARM template to update the table |

### Useful Diagnostic Commands

Run these on the Hybrid Worker VM:

```powershell
# Check Arc agent status
azcmagent show

# Check Hybrid Worker extension
Get-ChildItem "C:\Packages\Plugins\Microsoft.Azure.Automation.HybridWorker.HybridWorkerForWindows" -Recurse -Filter "*.status" | Get-Content

# Test SQL connectivity
Test-NetConnection -ComputerName "YOUR_SQL_IP" -Port 1433

# Check Managed Identity token
$response = Invoke-WebRequest -Uri "http://localhost:40342/metadata/identity/oauth2/token?resource=https://monitor.azure.com/&api-version=2020-06-01" -Headers @{Metadata="true"} -UseBasicParsing -SkipHttpErrorCheck
$response.StatusCode  # Should be 401 (challenge flow)
```

---

## FAQ

**Q: How many SQL Servers can I monitor?**  
A: There's no hard limit. A single Hybrid Worker can monitor hundreds of instances. The runbook processes them sequentially, so very large environments may benefit from multiple workers or parallel runbook jobs.

**Q: Does this install anything on the SQL Servers?**  
A: No. The solution is completely agentless on the SQL Servers. Only the Hybrid Worker VM needs the Automation extension.

**Q: Can I customize the collection interval?**  
A: Yes. Change the schedule frequency in Azure Automation. Common values: 5 minutes (high-frequency), 15 minutes, 1 hour.

**Q: Can I add more metrics to collect?**  
A: Yes. Modify the SQL queries in the runbook, add columns to the DCR stream declaration and the Log Analytics table, then update the workbook KQL queries.

**Q: What's the cost?**  
A: Main costs are Log Analytics data ingestion (~$2.76/GB) and Automation account job minutes (500 free/month, then ~$0.002/minute). For a typical environment monitoring 10 SQL instances hourly, expect < $5/month.

**Q: Does it work with Azure SQL Database or Managed Instances?**  
A: Currently, this solution targets SQL Server on VMs (IaaS/on-premises). Azure SQL Database and Managed Instances have built-in monitoring through Azure Monitor.

**Q: Can I use this without Azure Arc?**  
A: Yes. You can install the Hybrid Worker extension on a regular Azure VM, or use the legacy agent-based Hybrid Worker on any Windows Server.

---

## Next Steps

- **Set up alerts**: Create alert rules on the Log Analytics workspace for backup SLA violations
- **Pin to dashboard**: Pin workbook visualizations to an Azure Dashboard
- **Integrate with ITSM**: Use Logic Apps or Azure Functions to create tickets when critical backup alerts appear
- **Scale out**: Add more SQL instances by updating the `SqlInstances` Automation Account variable (no schedule changes needed)

---

*This guide was created as part of the SQL Server Monitoring Solution. For questions, contact your Microsoft representative.*
