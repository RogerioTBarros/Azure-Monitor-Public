# SQL Server Monitoring Solution — Customer Templates

> **Purpose**: Everything you need to deploy the SQL Server Monitoring solution in your Azure subscription.

---

## Contents

| File | Description |
|------|-------------|
| [arm-template-infrastructure.json](arm-template-infrastructure.json) | ARM template — supports existing or new Automation Account, Log Analytics Workspace, Custom Table, and Key Vault |
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
   - **Automation Account Name**: Name of your existing (or new) Automation Account
   - **Create Automation Account**: `false` to use existing, `true` to create a new one
   - **Automation Account Resource Group**: Resource group of the existing Automation Account (leave default if creating or if in same RG)
   - **Log Analytics Workspace Name**: Name of your existing (or new) workspace
   - **Create Log Analytics Workspace**: `false` to use existing, `true` to create a new one
   - **Log Analytics Workspace Resource Group**: Resource group of the existing workspace (leave default if creating or if in same RG)
   - **Location**: Azure region for new resources
   - **Enable Key Vault**: `true` if using SQL Authentication, `false` for Windows Authentication
   - **Create Key Vault**: `false` to use existing, `true` to create a new one (only if Enable Key Vault is `true`)
   - **Key Vault Name**: Name of existing or new Key Vault (SQL Auth only)
   - **Key Vault Resource Group**: Resource group of the existing Key Vault (leave default if creating or if in same RG)
7. Click **Review + Create → Create**
8. **IMPORTANT**: After deployment completes, go to the **Outputs** tab and copy the values shown

> **Note**: The custom table `SQLServerMonitoring_CL` is always created/updated, even when using an existing workspace. The deploying user needs Contributor access on the workspace's resource group.

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

# Use existing Automation Account, create new Log Analytics Workspace
.\Deploy-SQLMonitoringSolution.ps1 `
    -ResourceGroupName "rg-sql-monitoring" `
    -Location "eastus" `
    -AutomationAccountName "existing-automation-account" `
    -AutomationAccountResourceGroup "rg-shared-services" `
    -LogAnalyticsWorkspaceName "sql-monitoring-law" `
    -CreateLogAnalyticsWorkspace

# Create everything from scratch with SQL Authentication
.\Deploy-SQLMonitoringSolution.ps1 `
    -ResourceGroupName "rg-sql-monitoring" `
    -Location "eastus" `
    -AutomationAccountName "sql-monitoring-aa" `
    -CreateAutomationAccount `
    -LogAnalyticsWorkspaceName "sql-monitoring-law" `
    -CreateLogAnalyticsWorkspace `
    -SqlAuthenticationType "SQL" `
    -KeyVaultName "sql-monitoring-kv" `
    -CreateKeyVault

# Use all existing resources (different resource groups)
.\Deploy-SQLMonitoringSolution.ps1 `
    -ResourceGroupName "rg-sql-monitoring" `
    -Location "eastus" `
    -AutomationAccountName "existing-aa" `
    -AutomationAccountResourceGroup "rg-shared-services" `
    -LogAnalyticsWorkspaceName "existing-law" `
    -LogAnalyticsWorkspaceResourceGroup "rg-monitoring" `
    -SqlAuthenticationType "SQL" `
    -KeyVaultName "existing-kv" `
    -KeyVaultResourceGroup "rg-security"
```

---

## Architecture

```
SQL Server(s) ──TCP 1433──▶ Hybrid Worker VM ──HTTPS──▶ DCE ──▶ DCR ──▶ Log Analytics ──▶ Workbook
                             (Runbook on schedule)        (Logs Ingestion API)    (SQLServerMonitoring_CL)
```

## Support

For questions or issues, refer to the [Lab Guide](../Presentation/LabGuide-SQLServerMonitoring.md) for detailed troubleshooting steps.
