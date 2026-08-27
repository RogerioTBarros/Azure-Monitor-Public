# Upgrading an existing deployment to Workbook v2

This guide takes a working SQL Monitoring deployment and upgrades it to the **v2 workbook**,
using the Azure portal. Every step is done in the portal; no local tooling is required.

Allow about 30 minutes, plus a collection cycle to confirm data.

---

## What you get

| Capability | Why it matters |
|---|---|
| **Uptime / Availability tab** | Uptime % per instance, restart events, fleet uptime, daily availability trend |
| **Azure tag filter** | Scope the whole dashboard to one environment / criticality / owner, using your own resource tags |
| **Tag Coverage** | Shows what a tag filter would *hide* — instances on untagged nodes, and the machines that need tagging |
| **Database state filter** | Keeps non-ONLINE databases out of backup compliance (they cannot be backed up) |
| **System database filter** | Excludes `tempdb` by default |
| **Collection reliability** | Separates "SQL was down" from "we could not reach SQL" |

---

## What changes, and why it needs a schema update

The tag filter needs to know **which physical machine** an instance runs on, because Azure tags
live on the VM / Arc-enabled machine — not on SQL Server.

For a **failover cluster instance** this cannot be derived from existing data: both `SqlInstance`
and `ServerName` hold the cluster *virtual* name, which is not a tagged Azure resource. So the
collection now gathers two extra fields:

| Column | Source | Purpose |
|---|---|---|
| `PhysicalNodeName` | `SERVERPROPERTY('ComputerNamePhysicalNetBIOS')` | The computer currently running the instance. For an FCI this is the **active node**, and it changes on failover — so a clustered instance follows its tag across nodes. |
| `IsClustered` | `SERVERPROPERTY('IsClustered')` | `1` for a failover cluster instance, `0` for stand-alone |

Adding columns is **non-breaking**: existing data is preserved and older rows simply have the new
columns empty.

---

## ⚠️ Do the steps in this order

A Data Collection Rule **silently discards any field its stream does not declare** — no error is
raised, the column is simply absent in Log Analytics. If the runbook is published before the table
and DCR know about the new columns, the data is lost with no warning.

```
1. Table   →   2. DCR   →   3. Runbook   →   4. Workbook
```

---

## Step 1 — Add the columns to the custom table

1. Azure portal → **Deploy a custom template** (search for *Deploy a custom template*).
2. **Build your own template in the editor** → **Load file** → select `arm-template-infrastructure.json`.
3. **Save**, then fill in the parameters.

> **⚠️ Set both creation flags to `false`.** This template can create an Automation Account and a
> Log Analytics workspace. On an existing deployment you want it to touch **only** the table:
>
> | Parameter | Value |
> |---|---|
> | `createAutomationAccount` | **false** |
> | `createLogAnalyticsWorkspace` | **false** |
> | `logAnalyticsWorkspaceName` | your existing workspace name |
> | `logAnalyticsWorkspaceResourceGroup` | the workspace's resource group |
>
> With both flags `false`, the Automation Account and workspace are not modified at all — only the
> `SQLServerMonitoring_CL` table definition is updated.

4. **Review + create** → **Create**.

**Verify** — Log Analytics workspace → **Tables** → `SQLServerMonitoring_CL` → the schema should now
list `PhysicalNodeName` and `IsClustered`.

---

## Step 2 — Add the columns to the Data Collection Rule

1. Azure portal → **Deploy a custom template** → **Build your own template in the editor** →
   **Load file** → select `arm-template-data-collection.json`.
2. Set **Subscription** and **Resource group** to the group that **contains your existing DCR**.

> **⚠️ The resource group you deploy into is the single most important choice on this page.**
> The template finds the DCE *by name inside the deployment's resource group*. Deploying into any
> other group will either bind the DCR to a different endpoint that happens to share the name, or
> create a **second DCR with a new `immutableId`** while the runbook keeps writing to the old one.
>
> The **Region** field just above the parameters is disabled and follows the resource group. That is
> the *deployment's* own region and does **not** control where the DCE and DCR are created — the
> `location` parameter does. A resource group in one region routinely contains resources in another.

3. Fill in the parameters, using **exactly the same names** as your existing deployment:

   | Parameter | Value |
   |---|---|
   | `dataCollectionEndpointName` | your existing DCE name |
   | `createDataCollectionEndpoint` | **false** — v2 changes nothing in the DCE |
   | `dataCollectionRuleName` | your existing DCR name |
   | `logAnalyticsWorkspaceName` | your existing workspace name |
   | `logAnalyticsWorkspaceResourceGroup` | the workspace's resource group |
   | `location` | your **Log Analytics workspace's** region — the existing DCE and DCR must already be in it |

> **⚠️ Set `location` to the region of the existing resources — not the resource group's region.**
> `location` defaults to the *resource group's* location, and a resource group frequently holds
> resources in a different region. An Azure resource **cannot change region after it is created**, so
> deploying with the wrong value fails validation with:
>
> ```text
> The resource 'sql-monitoring-dce' already exists in location '<region-a>' in resource group
> '<rg-name>'. A resource with the same name cannot be created in location '<region-b>'.
> (Code: InvalidResourceLocation)
> ```
>
> Read the correct value from Monitor → **Data Collection Rules** → your DCR → **Location**, and
> confirm the DCE matches. Setting `createDataCollectionEndpoint` to **false** leaves the DCE
> completely untouched; the DCR is still updated in place and keeps its `immutableId`.
>
> Microsoft's guidance is that the DCR region "must match the region of the Log Analytics workspace
> and the DCE if you're using one", and a DCE's logs ingestion endpoint belongs in the same region as
> the destination workspace. If the three do not currently agree, align them on the **workspace's**
> region rather than deploying v2 on top of the mismatch.

4. **Review + create** → **Create**.

> **Keep the DCR name identical.** Deploying over the existing rule updates it in place and the
> **`immutableId` is preserved**, so no schedule or runbook parameter needs to change. Using a
> different name creates a *second* DCR with a new `immutableId`, and the runbook would keep
> writing to the old one.

**Verify** — Monitor → **Data Collection Rules** → your DCR → **Overview** → confirm the
`immutableId` is unchanged, then open the **JSON view** and confirm the two columns appear under
`streamDeclarations`.

### If the DCE or DCR was re-created in another region

Region is immutable, so "moving" a DCE or DCR means a **new resource**, even when the name is reused.
The in-place `immutableId` guarantee above does **not** apply in that case. After such a move:

1. Copy the new DCE **logs ingestion endpoint** (DCE → Overview) and the new DCR **`immutableId`**
   (DCR → Overview) — both differ from the old ones.
2. Update the runbook's `DceEndpoint` and `DcrImmutableId` parameters **and the schedule's copies of
   them**, otherwise collection keeps writing to the old region's resources.
3. Re-grant **Monitoring Metrics Publisher** on the new DCR to the Automation Account's
   system-assigned managed identity. Role assignments do not follow a re-created resource.
4. Leave the old DCE/DCR in place until data is confirmed arriving, then delete them once nothing
   references them.

---

## Step 3 — Update the runbook

1. Automation Account → **Runbooks** → `Get-SQLServerInfo-LogsIngestionApi` → **Edit**.
2. Replace the entire contents with `CustomerTemplates/Get-SQLServerInfo-LogsIngestionApi.ps1`.
3. **Save**, then **Publish**.

Nothing else changes — same runtime, same parameters, same schedule. The one exception is a DCE or DCR
that was re-created in another region, which changes the endpoint and `immutableId` (see Step 2).

---

## Step 4 — Run it and confirm the new data

1. On the runbook, click **Start**, supplying the usual parameters
   (`DceEndpoint`, `DcrImmutableId`, `SqlAuthenticationType`, `StreamName`).
2. When the job completes, check the **Output** tab — each instance reports
   *Authentication / Connection / Databases / Backup health / Status*.
3. Wait a few minutes for ingestion, then run this in **Logs**:

```kusto
SQLServerMonitoring_CL
| where TimeGenerated > ago(30m) and DatabaseName != "_ERROR"
| summarize by SqlInstance, ServerName, PhysicalNodeName, IsClustered
```

`PhysicalNodeName` should contain a machine name. For a failover cluster instance, expect
`ServerName` = the cluster virtual name and `PhysicalNodeName` = the node currently running it.

> **If the new columns come back empty, this is expected on the first run(s).** A DCR stream schema
> change takes a few minutes to reach the ingestion endpoint, and until it does the new fields are
> silently discarded — the job still reports success and the rows still arrive, just without the new
> columns. In testing, two collection runs in the first ~4 minutes after the DCR update stored the
> columns empty, and a run ~8 minutes after the update populated them correctly.
>
> Wait a few minutes, run the runbook again, and re-query. Use this to see it batch by batch:
>
> ```kusto
> SQLServerMonitoring_CL
> | where TimeGenerated > ago(1h)
> | summarize Rows = count(),
>             WithNode = countif(isnotempty(PhysicalNodeName)),
>             NodeSample = any(PhysicalNodeName)
>           by Batch = bin(TimeGenerated, 1m)
> | order by Batch desc
> ```
>
> Once a recent batch shows `WithNode` greater than zero, the upgrade is complete. If batches keep
> showing `WithNode = 0` well after the change, Step 2 did not apply — go back and check the DCR
> JSON view.

---

## Step 5 — Deploy the v2 workbook

1. Azure portal → **Deploy a custom template** → **Build your own template in the editor** →
   **Load file** → select `arm-template-workbook-v2.json`.
2. Set a display name (for example *SQL Server Monitoring Dashboard v2*) and a location matching
   your workspace.
3. **Review + create** → **Create**.

The existing v1 workbook is left untouched, so you can compare the two and switch over when ready.

To try it before deploying: Monitor → **Workbooks** → **New** → **Advanced Editor** (`</>`) →
paste the contents of `Workbooks/SQLServerMonitoring-v2.workbook` → **Apply**.

---

## Step 6 — Point the tag filter at your tag

Open the workbook and set the parameters at the top:

| Parameter | What to set |
|---|---|
| **Tag Name** | Your own tag key — defaults to `Environment`; change it to whatever your organisation uses |
| **Tag Value** | One or more values, or *All* to disable the tag filter |
| **Database State** | *Online only* (default) or *All states* |
| **System Databases** | *Exclude tempdb* (default), *Exclude all system databases*, or *Include everything* |

Then open **Instances → Tag Coverage** and work the two lists down to empty:

- **Monitored SQL with no tag on its node** — instances that a tag filter would hide.
- **Azure machines to tag** — the exact Arc machines / VMs to apply the tag to.

> **Tag every node of a cluster.** A failover cluster instance is only visible while its *active*
> node is tagged. If only one node is tagged, the instance disappears from a filtered dashboard at
> the next failover. Tag Coverage flags this as **Some nodes untagged** before that happens.

---

## Things worth knowing before you present it

- **`tempdb` is excluded by default.** It is recreated at every SQL Server start and can never be
  backed up, so counting it permanently reports `Never` and understates backup compliance.
  Database counts and compliance percentages will therefore differ from v1. *System Databases →
  Include everything* restores the v1 behaviour.
- **Uptime precision is bounded by the collection interval.** A restart time is exact, but the
  moment an instance went *down* is never observed, so downtime is measured conservatively as
  `restart time − last successful collection`. With an hourly schedule, one restart costs up to an
  hour of measured downtime. Figures like 99.99% are not attainable by polling at that frequency —
  increase the collection frequency if you need tighter numbers.
- **An FCI failover looks like a restart**, because it is one: the SQL service stops on one node and
  starts on the other.
- **Collection reliability is not SQL uptime.** A failed collection can be a network, firewall or
  permissions problem. The Uptime tab reports the two separately.

---

## Rolling back

Each step is independently reversible:

| To undo | Do this |
|---|---|
| Workbook | Delete the v2 workbook — v1 is untouched |
| Runbook | Re-paste the previous version and **Publish** |
| DCR / table | Leave them — the extra columns are harmless and ignored by v1 |

There is no need to remove the columns; the v1 workbook simply does not reference them.

---

## If something does not work

| Symptom | Cause | Fix |
|---|---|---|
| Step 2 fails with `InvalidResourceLocation` | `location` resolved to a different region than the existing DCE/DCR — the default is the *resource group's* region | Set `location` to the existing DCR's region and `createDataCollectionEndpoint` to **false** |
| Step 2 fails with `InvalidWorkspace` — workspace "is in different location" than the DCR | `location` does not match the workspace's region | Set `location` to the workspace's region |
| Step 2 fails with `InvalidEndpoint` — the DCE "does not exist in the region of the data collection rule" | The deployment is scoped to a resource group whose DCE is in another region; the template resolves the DCE by name **inside the deployment's resource group** | Deploy into the resource group that holds the DCR and its DCE |
| Tag Value dropdown is empty | No resource in the selected subscriptions carries that tag key | Check the **Tag Name** spelling; tag keys are case-sensitive |
| Tag filter returns nothing | `PhysicalNodeName` empty, or the node is not tagged | Step 4 verification, then **Tag Coverage** |
| Tag Coverage says *PhysicalNodeName not populated* | Steps 1–3 not completed, or not yet propagated | Re-run the runbook and re-query |
| An instance vanished after a failover | The new active node is not tagged | Tag **every** node of the cluster |
| Backup compliance dropped vs v1 | Expected if you switched to *Include everything* | Leave `tempdb` excluded |

For collection-level problems (worker prerequisites, SQL authentication, connectivity), see the
**Troubleshooting** section of [README.md](README.md).
