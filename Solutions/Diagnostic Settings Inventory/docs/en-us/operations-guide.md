# Operations Guide

How to run the diagnostic settings inventory end to end, from a first census to delivered CSVs.

🌐 **English** · [Português (pt-BR)](../pt-br/guia-de-operacao.md)

---

## 0. Before you start

### Two traps that silently corrupt a run

**1. Verify the uploaded script is the current one.** A stale copy produces a run that looks
entirely plausible. Assert on the artifact, not on memory:

```powershell
(Get-Command ./Get-DiagnosticSettingsInventory.ps1).Parameters.Keys -join ', '
```

It must list `SkipStorageServices`. The driver performs this check automatically and refuses
to start otherwise.

**2. Phase artifacts are shared across scopes.** `census-by-type.csv`,
`census-by-subscription.csv` and `supported-types.csv` are written to the same paths
regardless of `-ManagementGroupId` or `-SubscriptionId`. A **single-subscription pilot
therefore overwrites the tenant-wide census and probe cache**. Because Collect silently reuses
a cached `supported-types.csv`, a full run launched afterwards filters on the pilot's much
smaller type list and quietly misses most of the estate.

> **Always re-run Census and `Probe -Force` at full scope immediately before a full run**, and
> confirm the type count matches the whole estate rather than the pilot.

### Environment

| Requirement | Notes |
| --- | --- |
| Cloud Shell in **PowerShell** mode | Not Bash — Az cmdlets are unavailable there |
| Reader at the target scope | Anything unreadable is reported as `AccessDenied`, never dropped |
| `Az.Accounts` | Bundled in Cloud Shell; the only module required |
| Authentication | Cloud Shell is pre-authenticated. Do **not** run `Connect-AzAccount` |

```powershell
Get-AzContext | Format-List Account, Tenant, Environment
```

### ⚠ Cloud Shell storage may be ephemeral

Without a mounted file share, `$HOME` is container storage. Checkpoints survive `Ctrl+C` and a
script restart **within the same session**, but everything — scripts, checkpoints and output —
is lost when the session ends or the container recycles.

On an ephemeral session, back up to your own machine regularly:

```powershell
tar -czf ~/dsi-progress.tgz -C ~/Data checkpoints supported-types.csv census-by-type.csv census-by-subscription.csv
download ~/dsi-progress.tgz
```

Restore into a fresh session with:

```powershell
mkdir -p ~/Data
tar -xzf ~/dsi-progress.tgz -C ~/Data
```

Never promise "resume tomorrow, nothing is lost" without confirming persistence first.

---

## 1. Upload the scripts

Cloud Shell toolbar → **Upload/Download files** → *Upload*. Both scripts land in `$HOME`.

```powershell
cd ~
ls Get-DiagnosticSettingsInventory.ps1 Invoke-DiagnosticSettingsCollection.ps1
```

> **Path trap:** `-OutputDir` defaults to `Join-Path $PWD.Path 'Data'` → `~/Data`. That is
> deliberate. A default of `$PSScriptRoot/..` resolves to `/home` when the script is uploaded to
> the home directory, which is **not writable**, and the first write fails.

---

## 2. Census — always first

Costs about two Resource Graph calls and converts every estimate from a guess into a number.

```powershell
./Get-DiagnosticSettingsInventory.ps1 -ManagementGroupId '<mg-root-id>' -Phase Census
```

Produces `~/Data/census-by-type.csv` and `~/Data/census-by-subscription.csv`.

Read the console summary — distinct types, subscription count, total resources, and the largest
single subscription. **Stop and review before continuing.** Until this runs, any effort estimate
is fiction.

---

## 3. Probe — which types can even have settings

Determines which resource types in *this* estate support diagnostic settings, by calling the
`diagnosticSettings` endpoint against one sample resource per type. One to two calls per
distinct type — hundreds, not hundreds of thousands.

```powershell
./Get-DiagnosticSettingsInventory.ps1 -ManagementGroupId '<mg-root-id>' -Phase Probe
```

Produces `~/Data/supported-types.csv`:

| Column | Meaning |
| --- | --- |
| `ResourceType` | The type |
| `Supported` | `True` if the type accepts a diagnostic settings read |
| `ResourceCount` | How many resources of this type exist in scope |
| `Categories` | Category metadata, where available |
| `ProbeStatus` / `SettingsProbeStatus` | HTTP status of each probe call |
| `SupportReason` | Why the type was included or excluded |
| `SampleId` | The resource that was probed |

**Review this file before the full run — it is the filter that decides what gets scanned.**
Sort `Supported=False` by `ResourceCount` descending: that is where a mistake costs the most. If
a high-count type looks wrong, force it back in with `-AdditionalType`.

Results are cached. Re-probe with `-Force`.

> **Why the probe calls `diagnosticSettings` and not just `diagnosticSettingsCategories`:** a
> `200` from the categories endpoint does **not** mean the type supports diagnostic settings.
> Metrics-only types return `200` from categories and then fail the real read with
> `400 ResourceTypeNotSupported`. Probing the endpoint you will actually call is the only correct
> predicate — see the [design notes](design-notes.md#5-the-probe-predicate).

---

## 4. Pilot on one subscription

Never go straight to a full run.

```powershell
./Get-DiagnosticSettingsInventory.ps1 -SubscriptionId '<one-sub-id>' -TargetBatchesPerSecond 2
```

Watch the run summary:

- **`Throttled429` should be 0.** If not, lower `-TargetBatchesPerSecond`.
- **`SingleRequests` should be 0.** A non-zero value means batches are falling back to
  per-resource reads — usually an unsupported type contaminating the candidate set. This is a
  ~15x throughput collapse and must be fixed before the full run, not tolerated.
- **`HeadroomPauses`** near zero. Non-zero means the script is proactively slowing down.
- **`GraphQuotaPauses` may legitimately be non-zero** on large estates. Resource Graph has its
  own quota (~15 queries per 5 seconds per user), separate from the ARM read bucket. This is
  **not** a reason to lower `-TargetBatchesPerSecond`, which governs ARM load only.
- **Wall-clock per 1,000 resources** — but see the warning below before extrapolating.

> **Pacing is a floor, not a parallelism setting.** Requests are issued one at a time, so real
> throughput is `max(pacing interval, round-trip latency)`. If a batch takes 1.5s to return,
> raising `-TargetBatchesPerSecond` from 2 to 4 buys nothing.

> **⚠ Do not extrapolate from a small subscription.** Throughput is not linear in subscription
> size. A pilot on a small subscription can suggest a 2-hour full run that then takes far longer,
> because the largest subscriptions degrade into a much slower regime. Pilot on the largest
> subscription, or accept that the estimate is a lower bound.

---

## 5. Full run

### Small estates

```powershell
./Get-DiagnosticSettingsInventory.ps1 -ManagementGroupId '<mg-root-id>'
```

Resumable: re-running skips completed subscriptions and continues partial ones from the last
checkpointed resource.

### Large estates — use the driver

A single long-running process degrades progressively: batch round-trips grow from seconds to
minutes and the process eventually hangs, while a freshly started process serves the same
request in under two seconds. The cause is accumulated in-process state, not ARM latency and not
throttling. Restarting the same single process reproduces the same decay.

The fix is process isolation — one OS process per subscription, with a hard timeout:

```powershell
./Invoke-DiagnosticSettingsCollection.ps1 -BackupPath ~/dsi-progress.zip
```

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-ScriptPath` | sibling file | Path to the collector |
| `-OutputDir` | `./Data` | Must match the Census/Probe output directory |
| `-SubscriptionId` | from census CSV | Explicit subscription list |
| `-TimeoutSeconds` | `600` | Kill and retry an attempt that stalls |
| `-MaxAttempts` | `20` | Attempts per subscription before giving up |
| `-BackupPath` | — | Refresh a progress archive after each subscription |

The driver never passes `-Force`, skips subscriptions that already have a `.done` marker, and
reports any subscription it could not finish. **A stalled attempt loses nothing** — the collector
checkpoints after every batch, so the retry resumes where it stopped.

### Monitoring progress

```powershell
# completed subscriptions
(Get-ChildItem ~/Data/checkpoints/*.done).Count

# resources collected so far
(Get-Content ~/Data/checkpoints/*.jsonl | Measure-Object -Line).Lines
```

> The `.done` count is out of the number of subscriptions that contain at least one **supported**
> resource — not out of every subscription in the tenant. These differ, often substantially.

---

## 6. Export and retrieve

Export runs automatically at the end of a full run. To re-export from checkpoints without
re-collecting:

```powershell
./Get-DiagnosticSettingsInventory.ps1 -Phase Export
```

```powershell
download ~/Data/diagnostic-settings-summary.csv
download ~/Data/diagnostic-settings-detail.csv
download ~/Data/diagnostic-settings-rollup.csv
```

**Download immediately** on an ephemeral Cloud Shell session.

---

## 7. Reporting caveats to state explicitly

Include these in any deliverable. A reviewer who discovers them independently will distrust
every other number in the report.

1. **Rolling snapshot.** Each subscription is captured as of the moment it was processed, not a
   single instant. Row counts will not reconcile exactly against a fresh Resource Graph count on
   an active estate.
2. **Absent subscriptions.** Subscriptions with no supported resources produce zero rows. That
   means "nothing here can carry a diagnostic setting", not "nothing is logged". List them
   separately with the reason.
3. **Status distinctness.** `AccessDenied`, `NotFound`, `NotSupported` and `Error` are never
   merged into `NotConfigured`.
4. **Deleted resources.** Long runs will produce some `NotFound` rows for resources deleted
   between enumeration and read. This is expected, not a defect.

---

## 8. Tuning reference

| Parameter | Default | When to change |
| --- | --- | --- |
| `-TargetBatchesPerSecond` | `4` | Lower on any 429s. Raise only after a clean pilot — and only if latency, not pacing, is the floor |
| `-BatchSize` | `20` | Leave at 20; it matches the value used by Azure Quick Review |
| `-MinReadHeadroom` | `100` | Raise to be more cautious in a busy tenant |
| `-MaxRetries` | `5` | |
| `-ResourceType` | — | Scope to specific types, e.g. a critical-services-only pass |
| `-AdditionalType` | — | Force-include a type the probe wrongly excluded |
| `-SkipStorageServices` | off | Turns **off** storage sub-resource expansion. Faster, but storage **log** settings go uncollected |
| `-IncludeAllTypes` | off | Bypasses the probe filter. Much higher load — use only to prove nothing was missed |

### Storage sub-resource expansion

`Microsoft.Storage/storageAccounts` exposes only **metric** categories. The storage **log**
categories live on `blobServices`, `fileServices`, `queueServices` and `tableServices`, which
Resource Graph does **not** index — so they can never be enumerated.

Their IDs are deterministic (`<accountId>/<service>/default`), so Collect synthesizes all four
per account instead of enumerating them. Each account therefore costs 5 reads rather than 1.
Services that do not apply to an account's kind return 404, recorded as `NotFound` and kept
distinct from `NotConfigured`.

---

## 9. Troubleshooting

| Symptom | Action |
| --- | --- |
| `Access to the path '/home/Data' is denied` | `-OutputDir` resolved above `$HOME`. Pass `-OutputDir ~/Data` explicitly |
| A directory literally named `..\Data` | A Windows-style path leaked into `Join-Path`. Cloud Shell is Linux; `\` is a valid filename character |
| Repeated 429s | Halve `-TargetBatchesPerSecond`. Confirm no other tool is scanning the same subscriptions under the same identity — the bucket is **per service principal** |
| `RateLimiting` error citing `aka.ms/resourcegraph-throttling` | That is **Resource Graph**, a different bucket. Lowering `-TargetBatchesPerSecond` is the wrong lever; check `GraphQuotaPauses` |
| `SingleRequests` climbing | An unsupported type is contaminating batches. Re-run `Probe -Force` and check `SettingsProbeStatus` |
| Throughput decaying over hours, then a hang | Known process-level degradation. Switch to the driver so each subscription gets a fresh process |
| `Your Azure credentials have not been set up or have expired` mid-run | Transient managed-identity token blip on long runs. Do **not** run `Connect-AzAccount` in Cloud Shell; retry the subscription |
| Session dropped mid-run | Re-run the same command; checkpoints resume automatically |
| `No Azure context` | Cloud Shell is in Bash mode or the session expired. Switch to PowerShell mode and reload |
| Export says "no checkpoints found" | Wrong `-OutputDir`, or the restore of a progress archive failed. **Stop** — re-collecting repeats hours of work |
