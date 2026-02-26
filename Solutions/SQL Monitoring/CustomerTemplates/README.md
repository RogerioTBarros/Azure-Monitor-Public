# SQL Server Monitoring Solution — Customer Templates

> **Purpose**: Everything you need to deploy the SQL Server Monitoring solution in your Azure subscription.

---

## Contents

| File | Description |
|------|-------------|
| [arm-template-infrastructure.json](arm-template-infrastructure.json) | ARM template for Automation Account, Log Analytics Workspace, Custom Table, and Key Vault |
| [arm-template-data-collection.json](arm-template-data-collection.json) | ARM template for Data Collection Endpoint (DCE) and Data Collection Rule (DCR) |
| [arm-template-workbook.json](arm-template-workbook.json) | ARM template for the Azure Monitor Workbook (4-tab dashboard) |
| [Get-SQLServerInfo-LogsIngestionApi.ps1](Get-SQLServerInfo-LogsIngestionApi.ps1) | PowerShell runbook script (import into Azure Automation) |
| [Deploy-SQLMonitoringSolution.ps1](Deploy-SQLMonitoringSolution.ps1) | Automated deployment helper script (optional, uses Azure CLI) |

---

## Quick Start — Deploy via Azure Portal

The simplest way to deploy is through the Azure Portal using the ARM templates. No command-line tools required.

### Step 1: Deploy Infrastructure

1. Open the **Azure Portal**
2. Search for **"Deploy a custom template"** in the top search bar
3. Click **"Build your own template in the editor"**
4. Click **"Load file"** and select `arm-template-infrastructure.json`
5. Click **Save**
6. Fill in the parameters:
   - **Resource Group**: Create new or select existing
   - **Automation Account Name**: Choose a name (e.g., `mycompany-sql-monitoring-aa`)
   - **Log Analytics Workspace Name**: Choose a name (e.g., `mycompany-sql-monitoring-law`)
   - **Location**: Select your preferred Azure region
   - **Enable Key Vault**: `true` if using SQL Authentication, `false` for Windows Authentication
   - **Key Vault Name**: Required only if Enable Key Vault is `true`
7. Click **Review + Create → Create**
8. **IMPORTANT**: After deployment completes, go to the **Outputs** tab and copy the values shown

### Step 2: Deploy Data Collection

1. Repeat the process: **Deploy a custom template → Build your own → Load file**
2. Select `arm-template-data-collection.json`
3. Fill in the parameters:
   - **Log Analytics Workspace Name**: The same name from Step 1
   - **Data Collection Endpoint Name**: e.g., `sql-monitoring-dce`
   - **Data Collection Rule Name**: e.g., `dcr-sql-monitoring`
   - **Location**: Must match the workspace region
4. Click **Review + Create → Create**
5. Go to the **Outputs** tab and copy `dceEndpoint` and `dcrImmutableId`

### Step 3: Configure RBAC

1. Go to **Data Collection Rules** → your DCR
2. Click **Access control (IAM) → Add → Add role assignment**
3. Role: **Monitoring Metrics Publisher**
4. Members → **Managed identity** → Select → pick your Automation Account
5. Review + assign

(For SQL Auth: repeat for Key Vault with **Key Vault Secrets User** role)

### Step 4: Set Up Hybrid Worker

1. Go to **Automation Account → Hybrid Worker Groups → Create**
2. Add your Arc-enabled server or Azure VM
3. Wait for the worker to show **Connected** status (~5 minutes)

### Step 5: Import Runbook

1. Go to **Automation Account → Runbooks → Create**
2. Name: `Get-SQLServerInfo-LogsIngestionApi`
3. Type: **PowerShell**, Runtime version: **7.2**
4. Click **Create**, then paste the content of `Get-SQLServerInfo-LogsIngestionApi.ps1`
5. Click **Save → Publish**

### Step 6: Create SQL Instances Variable

1. **Automation Account → Variables → Add a variable**
2. Name: `SqlInstances`
3. Type: **String**
4. Value: A JSON array of your SQL Server addresses, e.g.:
   ```json
   ["Server1", "Server2", "10.0.0.5"]
   ```
5. Encrypted: **No** (so it can be updated easily when instances change)
6. Click **Create**

> **Tip**: When IPs or instances change, simply update this variable — no need to touch the schedule.

### Step 7: Create Schedule

1. **Automation Account → Schedules → Add a schedule**
2. Name: `SQLMonitoring-Hourly`, Recurrence: Every 1 hour
3. Link the schedule to the runbook with these parameters:

| Parameter | Value |
|-----------|-------|
| SqlAuthenticationType | `Windows` or `SQL` |
| DceEndpoint | DCE endpoint from Step 2 outputs |
| DcrImmutableId | DCR immutable ID from Step 2 outputs |
| StreamName | `Custom-SQLServerMonitoring_CL` |
| KeyVaultName | Your KV name (SQL Auth only) |
| SqlUsernameSecretName | `SqlMonitorUsername` (SQL Auth only) |
| SqlPasswordSecretName | `SqlMonitorPassword` (SQL Auth only) |

> **Note**: `SqlInstances` is not passed as a parameter — the runbook reads it automatically from the Automation Account variable created in Step 6.

4. Run on: **Hybrid Worker** → select your group

### Step 8: Deploy Workbook

1. **Deploy a custom template → Build your own → Load file**
2. Select `arm-template-workbook.json`
3. Fill in:
   - **Workbook Display Name**: `SQL Server Monitoring Dashboard`
   - **Location**: Same region as your workspace
4. Click **Review + Create → Create**

### Step 9: Verify

1. After running the first scheduled job (or a manual test run), wait 5-10 minutes
2. Go to **Azure Portal → Monitor → Workbooks**
3. Open "SQL Server Monitoring Dashboard"
4. Select your Subscription, Workspace, and Time Range

---

## Quick Start — Automated Script (PowerShell)

If you prefer command-line deployment:

```powershell
# Login to Azure
az login

# Deploy everything with Windows Authentication
.\Deploy-SQLMonitoringSolution.ps1 `
    -ResourceGroupName "rg-sql-monitoring" `
    -Location "eastus" `
    -AutomationAccountName "sql-monitoring-aa" `
    -LogAnalyticsWorkspaceName "sql-monitoring-law"

# Deploy with SQL Authentication
.\Deploy-SQLMonitoringSolution.ps1 `
    -ResourceGroupName "rg-sql-monitoring" `
    -Location "eastus" `
    -AutomationAccountName "sql-monitoring-aa" `
    -LogAnalyticsWorkspaceName "sql-monitoring-law" `
    -SqlAuthenticationType "SQL" `
    -KeyVaultName "sql-monitoring-kv"
```

---

## Architecture

```
SQL Server(s) ──TCP 1433──▶ Hybrid Worker VM ──HTTPS──▶ DCE ──▶ DCR ──▶ Log Analytics ──▶ Workbook
                             (Runbook on schedule)        (Logs Ingestion API)    (SQLServerMonitoring_CL)
```

## Support

For questions or issues, refer to the [Lab Guide](../Presentation/LabGuide-SQLServerMonitoring.md) for detailed troubleshooting steps.
