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

> **⚠️ Required before the runbook can run — install PowerShell 7.2 on every worker.**
> Extension-based Hybrid Workers do **not** ship PowerShell 7.x, and a runtime-7.2 runbook will fail with *"…is not recognized as a command… Install the language interpreter"*. On **each** worker:
>
> 1. Install **PowerShell 7.2 LTS** using the **MSI** (Windows Server 2019 has no winget).
> 2. Set the **machine-scope** environment variable `powershell_7_2_path` to the full path of `pwsh.exe`, normally `C:\Program Files\PowerShell\7\pwsh.exe`.
> 3. Restart the **`HybridWorkerService`** service.
>
> Verify with:
>
> ```powershell
> [Environment]::GetEnvironmentVariable('powershell_7_2_path','Machine')
> Test-Path 'C:\Program Files\PowerShell\7\pwsh.exe'
> ```
>
> Do **not** standardise on PowerShell 7.6.x — Azure Automation only recognises the 7.1 / 7.2 / 7.4 runtimes (there is no `powershell_7_6_path`), so pairing a 7.2 runbook with 7.6 is unsupported.
>
> **Install machine-wide, not from the Microsoft Store.** A Store/`msstore` install puts `pwsh.exe` under `%LOCALAPPDATA%\Microsoft\WindowsApps` as a *per-user* app-execution alias. Hybrid Worker jobs run as **Local System**, which cannot read or execute that path — the environment variable will look correct and every job will still fail.
>
> **This setting is fragile.** `powershell_7_2_path` is a plain environment variable that nothing recreates. Upgrading PowerShell, re-provisioning a worker or reverting a VM checkpoint can silently clear it, and collection then stops with no alert. See [Keep the pipeline honest](#keep-the-pipeline-honest).

### Step 5: Import Runbook

1. Go to **Automation Account → Runbooks → Create**
2. Name: `Get-SQLServerInfo-LogsIngestionApi`
3. Type: **PowerShell**, Runtime version: **7.2**
4. Click **Create**, then paste the content of `Get-SQLServerInfo-LogsIngestionApi.ps1`
5. Click **Save → Publish**

> **Managed identity note**: The runbook acquires Azure tokens directly from the built-in Azure Automation managed identity endpoint — **no Az modules are required**. Ensure the Automation Account has a **system-assigned** managed identity, and that the roles from Step 3 (Monitoring Metrics Publisher on the DCR, and Key Vault Secrets User for SQL Auth) are assigned to **that** identity.

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

> **⚠️ Prefer host names over IP addresses when using Windows Authentication.** Windows Auth against an **IP address** cannot use Kerberos — there is no Service Principal Name registered for a bare IP, so the client falls back to NTLM. From a Hybrid Worker (running as Local System) that fallback typically cannot present the machine account to a *remote* instance, and SQL Server rejects the session as:
>
> ```text
> Login failed for user 'NT AUTHORITY\ANONYMOUS LOGON'.
> ```
>
> A SQL instance on the worker **itself** still succeeds over an IP, so a partial failure where only the local instance reports is a strong signal of this problem. Use the host name or FQDN (which lets Kerberos match the SQL SPN), or switch that instance to **SQL Authentication**. IP addresses are fine for SQL Auth.

> **Clustered SQL Servers — Failover Cluster Instance (FCI)**: List the **virtual network name** (the clustered SQL Server Network Name) — **one entry per FCI**, and **not** the physical node names (the passive node has SQL stopped and would just report connection failures). An FCI is a single instance on shared storage, so the virtual name always reaches the active node and sees the **complete backup history** (`msdb` is shared). Grant the read-only rights **once per FCI** — the login lives in `master` on shared storage and persists across nodes. Note: instance **uptime resets on failover** (the SQL service restarts on the new node), so a low uptime value can simply mean a recent failover, not an outage.
>
> &nbsp;&nbsp;&nbsp;&nbsp;**Tagging a cluster**: you still list only the virtual name, but Azure tags are read from the **physical node** (the VM / Arc machine). The collector records the active node in `PhysicalNodeName`, so apply the tag to **every node** of the cluster — otherwise the instance vanishes from a tag-filtered dashboard as soon as it fails over to an untagged node. See [Upgrading an existing deployment](#adding-physicalnodename--isclustered).
>
> **Always On availability group (AG)**: List **each replica's instance name** (one entry per replica), not just the listener — otherwise you miss secondary-node uptime, and backups taken on a secondary replica (which land in that replica's own local `msdb`) won't appear when you query only the primary. Apply the read-only grant on **every** replica.

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

> **SQL permissions (Windows Auth)**: The runbook connects to SQL as the **Hybrid Worker's computer account** (`DOMAIN\WORKER$`) — grant that account, or (recommended) an **AD group** containing the worker computer accounts, **read-only** rights on each target SQL Server. See [Runbooks/README.md → SQL Server Authentication & Permissions](../Runbooks/README.md#sql-server-authentication--permissions) for the exact, documentation-grounded `GRANT` script. For **SQL Auth**, grant the same read-only rights to the SQL login stored in Key Vault.

4. Run on: **Hybrid Worker** → select your group

### Step 8: Deploy Workbook

1. **Deploy a custom template → Build your own → Load file**
2. Select `arm-template-workbook.json`
3. Fill in:
   - **Workbook Display Name**: `SQL Server Monitoring Dashboard`
   - **Location**: Same region as your workspace
4. Click **Review + Create → Create**

> **v2 workbook** (`arm-template-workbook-v2.json`) adds an Uptime / Availability tab, an Azure tag filter and two database filters. Note that it **excludes `tempdb` by default** — it is recreated at every SQL Server start and can never be backed up, so counting it permanently reports `Never` and understates backup compliance. Database counts and compliance percentages will therefore differ from v1; the active setting is shown in the Summary, Databases and Backups headers, and **System Databases → Include everything** restores the v1 behaviour.

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

## Upgrading an existing deployment

### Adding `PhysicalNodeName` / `IsClustered`

These two columns let the workbook filter SQL Servers by **Azure resource tag**. Tags live on
the VM or Arc-enabled machine, but a clustered instance reports only its cluster *virtual*
name in `SqlInstance` and `ServerName` — neither of which is a tagged Azure resource.
`PhysicalNodeName` comes from `SERVERPROPERTY('ComputerNamePhysicalNetBIOS')`, which is the
computer actually running the instance and **changes as an FCI fails over**, so it matches the
tagged resource and follows the instance across nodes.

> **⚠️ Order matters.** The DCR silently discards any field its stream does not declare — no
> error, no warning, the column is simply absent in Log Analytics. Update the table and the
> DCR **before** publishing the new runbook.

1. Redeploy `arm-template-infrastructure.json` (adds the two columns to `SQLServerMonitoring_CL`).
   Adding columns is non-breaking and preserves existing data.
2. Redeploy `arm-template-data-collection.json` (adds the two columns to the DCR stream).
   Deploying over the existing DCR keeps the same `dcrImmutableId`, so no schedule changes are needed.
3. Re-paste `Get-SQLServerInfo-LogsIngestionApi.ps1` into the runbook and **Publish**.
4. Deploy `arm-template-workbook-v2.json`.

Confirm the new column is populated after the next run:

```kusto
SQLServerMonitoring_CL
| where TimeGenerated > ago(2h) and DatabaseName != "_ERROR"
| summarize by SqlInstance, ServerName, PhysicalNodeName, IsClustered
```

For an FCI, expect `ServerName` = the virtual name and `PhysicalNodeName` = the active node.
Ensure the tag is applied to **every** node of the cluster, otherwise the instance disappears
from the dashboard whenever it fails over to an untagged node.

The v2 workbook checks this for you: **Instances → Tag Coverage** lists every monitored instance
whose node carries no tag, and the Azure machines that need tagging. Both views ignore the Tag
Value selection, so they show exactly what a tag filter would hide.

An instance that is **down or unreachable** still appears under its tag — a failed poll reports no
node, so the workbook carries each instance's last known node forward within the selected time
range. Only an instance never collected successfully in that range has no node to match on.

> Steps 1–3 are only required for the tag filter. If you don't filter by tag, the existing
> deployment keeps working unchanged, and the v2 workbook falls back to the older matching keys.

---

## Troubleshooting

Run the runbook manually first and read the job **Output** tab — it prints a per-instance
**Authentication / Connection / Databases / Backup health / Status** block plus a
`total | succeeded | failed` summary, which isolates most problems immediately.

| Symptom in the job output | Most likely cause | Fix |
|---|---|---|
| `…is not recognized as a command… Install the language interpreter` | PowerShell 7.2 missing on the worker, or `powershell_7_2_path` empty / pointing at a per-user `WindowsApps` alias | [Step 4 prerequisite](#step-4-set-up-hybrid-worker) |
| `Login failed for user 'NT AUTHORITY\ANONYMOUS LOGON'` | Windows Auth over an **IP address** (no SPN → NTLM → no machine account presented) | Use the host name / FQDN, or switch that instance to SQL Auth |
| `Login failed for user 'DOMAIN\WORKER$'` | Worker machine account has no SQL login | Apply the `GRANT` script in [Runbooks/README.md](../Runbooks/README.md#sql-server-authentication--permissions) |
| `provider: Named Pipes Provider, error: 40` | TCP/IP protocol disabled, SQL service stopped, wrong address, or firewall | Enable **TCP/IP** in SQL Server Configuration Manager, confirm 1433 is listening, open the firewall |
| `Invalid URI: The hostname could not be parsed` | Token call missing the `Metadata: True` header | Re-paste the current runbook — the shipped version already handles this |
| Job status **Suspended**, no output | Schedule linked without the mandatory parameters | Re-link the schedule with `DceEndpoint` and `DcrImmutableId` ([Step 7](#step-7-create-schedule)) |
| Only the instance co-located with the worker reports | Remote Windows Auth failing (see `ANONYMOUS LOGON` above) | Same fix |
| Rows arrive but every database shows `Never` / `Critical` | Worker account cannot read `msdb.dbo.backupset` | Grant `SELECT ON OBJECT::dbo.backupset` in `msdb` |
| Tag filter in the workbook returns nothing | `PhysicalNodeName` missing (table/DCR not updated), or the node isn't tagged | [Upgrading an existing deployment](#adding-physicalnodename--isclustered); check **Instances → Tag Coverage** |

### Keep the pipeline honest

Every failure mode above is **silent** — the schedule keeps running and the workbook simply
stops gaining rows. Create an alert rule on the absence of data so a broken worker surfaces
on its own:

```kusto
SQLServerMonitoring_CL
| where TimeGenerated > ago(2h)
| summarize Rows = count()
| where Rows == 0
```

Alert when the result is non-empty, evaluated every hour. For per-instance coverage, alert on
instances whose most recent record is an `_ERROR` row:

```kusto
SQLServerMonitoring_CL
| where TimeGenerated > ago(2h)
| summarize LastPoll = max(TimeGenerated),
            LastError = maxif(TimeGenerated, DatabaseName == "_ERROR")
          by SqlInstance
| where isnotnull(LastError) and LastError == LastPoll
```

---

## Architecture

```
SQL Server(s) ──TCP 1433──▶ Hybrid Worker VM ──HTTPS──▶ DCE ──▶ DCR ──▶ Log Analytics ──▶ Workbook
                             (Runbook on schedule)        (Logs Ingestion API)    (SQLServerMonitoring_CL)
```

## Support

For questions or issues, refer to the [Lab Guide](../Presentation/LabGuide-SQLServerMonitoring.md) for detailed troubleshooting steps.
