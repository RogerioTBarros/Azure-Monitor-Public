# Design Notes

Why this solution is built the way it is, what was measured rather than assumed, and which
alternatives were considered.

🌐 **English** · [Português (pt-BR)](../pt-br/notas-de-design.md)

Every claim below carries its source. Findings marked **measured** were verified empirically
against a real large estate rather than inferred from documentation.

---

## 1. The API, and why the portal does not scale

The Azure portal's **Azure Monitor → Diagnostic settings** blade enumerates resources and then
issues one read per resource, wrapped in ARM batch requests. That is why it pages endlessly on
large subscriptions and offers no export: it is a UI over a per-resource API, not over an index.

```http
GET https://management.azure.com/{resourceUri}/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview
```

Returns a `DiagnosticSettingsResourceCollection` — `value[]`, each item exposing
`properties.workspaceId`, `properties.storageAccountId`,
`properties.eventHubAuthorizationRuleId`, `properties.eventHubName`,
`properties.marketplacePartnerId`, `properties.logs[]` and `properties.metrics[]`.

> Source: [Diagnostic Settings - List (Azure Monitor REST API)](https://learn.microsoft.com/en-us/rest/api/monitor/diagnostic-settings/list)

A useful constraint: **each resource can have at most five diagnostic settings**, so every
response is small and bounded.

> Source: [Diagnostic settings in Azure Monitor](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings)

---

## 2. The constraint that shapes everything: Resource Graph cannot answer this

**Azure Resource Graph does not index diagnostic settings.** This eliminates the obvious "just
write a KQL query" answer.

- The `insightresources` table contains only `microsoft.insights/datacollectionruleassociations`
  and `microsoft.insights/tenantactiongroups`.
- The `resources` table contains many `microsoft.insights/*` types — `actiongroups`,
  `activitylogalerts`, `autoscalesettings`, `components`, `datacollectionrules`,
  `guestdiagnosticsettings`, `metricalerts`, `scheduledqueryrules`, `webtests`, `workbooks` —
  but **not** `microsoft.insights/diagnosticsettings`.

> Source: [Supported Azure Resource Manager resource types — Azure Resource Graph](https://learn.microsoft.com/en-us/azure/governance/resource-graph/reference/supported-tables-resources)

⚠ `microsoft.insights/guestdiagnosticsettings` **is** listed. That is the legacy *guest*
diagnostics type — a different thing. Do not mistake it for resource diagnostic settings.

### 2.1 The `useResourceGraph=true` escape hatch does not help

ARM offers a Resource Graph-backed GET/LIST path to relieve read throttling:

```http
GET https://management.azure.com/{resourceId}?api-version={v}&useResourceGraph=true
```

Its documented coverage is **only types in the `resources` and `computeresources` tables**, and
*"any unsupported/unroutable requests result in `useResourceGraph=true` ignored, and the call is
automatically routed to the resource provider."* Since diagnostic settings are in neither table,
the flag silently does nothing here.

> Source: [Azure Resource Graph GET/LIST API guidance](https://learn.microsoft.com/en-us/azure/governance/resource-graph/concepts/azure-resource-graph-get-list-api)

**Conclusion:** the only ways to learn diagnostic-settings state are to ask ARM per resource, or
to have Azure evaluate it via Azure Policy and read the compliance result.

---

## 3. The throttling budget

ARM uses a per-region **token bucket** model:

| Scope | Operation | Bucket | Refill / sec |
| --- | --- | --- | --- |
| Subscription | reads | 250 | 25 |
| Subscription | writes | 200 | 10 |
| Tenant | reads | 250 | 25 |
| Tenant | writes | 200 | 10 |

Subscription limits apply **per subscription, per service principal, per operation type**, with
global limits equal to 15× the individual service principal limits. On exhaustion: HTTP 429 with
`Retry-After`. Observable headroom: `x-ms-ratelimit-remaining-subscription-reads` and
`x-ms-ratelimit-remaining-tenant-reads`.

> Source: [Understand how Azure Resource Manager throttles requests](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/request-limits-and-throttling)

This inverts the naive scan design: parallelism *across* subscriptions is cheap because each has
its own bucket, while parallelism *within* one subscription is what triggers 429s.

### 3.1 Measured: the run is latency-bound, not throttle-bound

The open question was whether a 20-item batch decrements the read bucket by 1 or by 20. The
honest answer is that **it does not matter**:

- Every batch sub-response reports its own rate-limit headers. In a 2-item batch, both
  sub-responses reported 249 remaining.
- 249 of a 250 bucket refilling at 25/sec is simply "250 minus the request in flight". At a few
  requests per second the bucket refills faster than it is consumed, so it never visibly moves.
- Across hundreds of pilot calls the header never dropped below 249, with zero 429s.

**Capacity planning is therefore driven by round-trip latency and call count, not bucket
arithmetic.** Requests are issued serially, so throughput is
`max(pacing interval, round-trip latency)`. Raising the pacing target above the inverse of
measured latency achieves nothing.

### 3.2 Measured: batch sub-responses carry no correlation field

A sub-response contains exactly `httpStatusCode`, `headers`, `content` and `contentLength`.
There is **no name, no echoed `relativeUrl`, and no request identifier** tying it back to a
sub-request.

Two consequences drive the implementation:

1. Results must be attributed by parsing **each returned setting's own `id`**, truncated at
   `/providers/microsoft.insights/diagnosticsettings/` — never by array index.
2. A non-200 sub-response **cannot be attributed**, so the entire batch must be re-read one
   resource at a time to place the failure precisely. This is the single biggest performance
   cliff in the design.

---

## 4. The batch mechanism, validated against first-party code

```http
POST https://management.azure.com/batch?api-version=2020-06-01
Content-Type: application/json

{
  "requests": [
    { "httpMethod": "GET", "relativeUrl": "<resourceId>/providers/microsoft.insights/diagnosticSettings?api-version=2021-05-01-preview" }
  ]
}
```

This is not reverse-engineered from a browser. It is what **Azure Quick Review (`azqr`)**, a
Microsoft-maintained MIT-licensed tool, does in `internal/scanners/diagnostics_settings.go`:

| Parameter | Value in azqr |
| --- | --- |
| Batch size | **20** sub-requests per POST |
| Worker count | 30 concurrent workers |
| Client-side ARM limiter | 20 ops/sec, burst 100 |
| Retries | 5, delay 4s → max 60s |
| Header watched | `x-ms-ratelimit-remaining-tenant-reads` |
| Result derivation | parse the returned setting's `id` to recover the parent resource |

> Source: [Azure/azqr — `internal/scanners/diagnostics_settings.go`](https://github.com/Azure/azqr/blob/main/internal/scanners/diagnostics_settings.go)

These proven values are reused rather than reinvented. **Measured:** batch fan-out is genuinely
parallel server-side — a 2-item batch took ~0.61s (0.305 s/item) while a 20-item batch took
~1.64s (0.082 s/item). Sub-linear scaling confirms the batch is not processed serially.

---

## 5. The probe predicate

**This is the most expensive lesson in the project.**

The original probe decided type support from `diagnosticSettingsCategories`. That is wrong:

> **A `200` from `diagnosticSettingsCategories` does not mean the type supports diagnostic
> settings.** Metrics-only types return `200 { AllMetrics, categoryType: "Metrics" }` from the
> categories endpoint, and then fail the actual read with:
>
> ```
> 400 { "code": "ResourceTypeNotSupported",
>       "message": "The resource type '<type>' does not support diagnostic settings." }
> ```

Confirmed on `microsoft.network/privateendpoints` — a type that can easily represent a
double-digit percentage of a modern estate.

The cost of getting this wrong is not merely a mislabelled row. Unsupported resources inside an
ARM batch produce non-200 sub-responses, and because sub-responses carry no correlation field
(§3.2), **one bad resource forces the whole 20-item batch to be re-read individually**. In
testing, a single contaminating type turned 50 batches into 726 single reads — a ~15x throughput
collapse that would have been silent.

**Rules that follow:**

- Probe the endpoint you will actually call. Support means `diagnosticSettings` returns 200.
- Use `diagnosticSettingsCategories` only for category metadata, never as the predicate.
- `400 ResourceTypeNotSupported` is the canonical "not supported" answer from both endpoints —
  it is not a malformed request. Map it to a distinct `NotSupported` status, never to `Error`
  and never to "disabled".
- Do not hardcode a supported-type list. It rots as Azure ships services, creating silent blind
  spots. Probing costs one to two calls per distinct type and produces an auditable
  `supported-types.csv`.

---

## 6. Storage accounts need sub-resource expansion

`Microsoft.Storage/storageAccounts` exposes only **metric** categories. Storage **log**
categories live on `blobServices`, `fileServices`, `queueServices` and `tableServices` — which
Resource Graph does not index, so they can never be enumerated.

Their IDs are deterministic (`<accountId>/<service>/default`), so the collector synthesizes all
four per account. **Measured:** all four endpoints return HTTP 200 even when the service is
unused, and including them materially increased the `Enabled` count. Without this expansion, a
storage-heavy estate silently under-reports.

---

## 7. Measured: long-lived collector processes degrade

On a multi-hour run, throughput decayed monotonically from a clean start and ended in a stall.
Consecutive 500-resource blocks took 153s, 54s, 204s, 219s, 329s, then over 900s.

Crucially, this is **not** ARM latency and **not** throttling: while the collector was stalled on
a subscription, a separate freshly launched shell served a 20-item batch against that same
subscription in 1.64s. Restarting the collector reproduced the same decay from a clean start. The
best-supported explanation is accumulating in-process network/handle state, consistent with the
transient managed-identity token failures observed on the same timeline.

**Mitigation:** one OS process per subscription with a hard timeout, which bounds any stall and
prevents degradation from accumulating. Invoking the script again *inside the same session* does
not create a new process and does not help.

This is what `Invoke-DiagnosticSettingsCollection.ps1` implements.

---

## 8. Alternatives considered

### A — Audit-only Azure Policy + compliance query

Assign the destination-agnostic built-in policy, let Azure evaluate compliance on its own
infrastructure, then read results from Resource Graph in one query. **Zero per-resource ARM load.**

| Field | Value |
| --- | --- |
| ID | `7f89b1eb-583c-429a-8828-af049802c1d9` |
| Display name | Audit diagnostic setting for selected resource types |
| Effect | `AuditIfNotExists` — **hardcoded, not parameterised** |
| Parameters | `listOfResourceTypes`, `logsEnabled` (default `true`), `metricsEnabled` (default `true`) |

> Source: [Azure/azure-policy — `Monitoring/DiagnosticSettingsForTypes_Audit.json`](https://github.com/Azure/azure-policy/blob/master/built-in-policies/policyDefinitions/Monitoring/DiagnosticSettingsForTypes_Audit.json)

**Pros:** cannot mutate anything; destination-agnostic; one management-group assignment covers
every subscription; compliance lands in the indexed `policyresources` table; re-evaluates
continuously, so it becomes a durable control instead of a stale spreadsheet.

**Cons:** requires creating a policy assignment — a configuration change needing approval even
though it is audit-only. And **the existence condition is stricter than "has a diagnostic
setting"**: with defaults, a setting that collects logs but not `AllMetrics` reports
non-compliant. Tune deliberately, or run two assignments and compare.

> The `allLogs` / `audit` category-group initiatives are **destination-specific** — they flag a
> resource non-compliant if it ships to a different destination. Wrong tool for an inventory
> question.

**Choose this** when the inventory becomes a recurring control rather than a one-off report.

### B — Custom Resource Graph + ARM batch collector

**What this repository implements.** Highest fidelity: destination type and target IDs, setting
names, enabled categories, metrics flag. No tenant change. Reusable and re-runnable. The cost is
owning the throttling behaviour, which is why the pilot protocol is mandatory.

### C — Run `azqr` directly

```bash
azqr scan --management-group-id <mgId> --stages diagnostics
```

Zero code to maintain and battle-tested throttling. But its diagnostics output is framed as
*recommendations* — it reports resources **without** settings, so a full enabled/disabled picture
requires joining against its inventory output. Its supported-type filter is a hardcoded list
inside the tool, and introducing a third-party binary may itself need approval.

### D — Log Analytics cross-check

```kusto
union withsource=TableName AzureDiagnostics, AzureMetrics
| where TimeGenerated > ago(7d)
| summarize LastSeen = max(TimeGenerated) by _ResourceId, TableName
```

Zero ARM load, and it answers the arguably more useful question: *is data actually arriving?* It
catches settings that exist but deliver nothing. But it is **not a substitute** — blind to Event
Hub and Storage destinations, blind to configured-but-silent resources, and resource-specific
tables live outside `AzureDiagnostics`. **Use it as a validation layer, never on its own.**

---

## 9. Output schema

| Column | Notes |
| --- | --- |
| `SubscriptionId` / `SubscriptionName` | Name resolved from `resourcecontainers` |
| `ResourceGroup`, `ResourceName`, `ResourceType`, `Location` | |
| `ResourceId` | Full ARM ID — the join key |
| `DiagnosticStatus` | `Enabled` / `NotConfigured` / `NotSupported` / `AccessDenied` / `NotFound` / `Error` |
| `SettingsCount` | 0–5 |
| `SettingNames` | Semicolon-joined |
| `DestinationTypes` | `LogAnalytics;EventHub;Storage;Partner` |
| `WorkspaceIds`, `StorageAccountIds`, `EventHubNames` | Semicolon-joined |
| `LogCategories` | Semicolon-joined categories and category groups |
| `MetricsEnabled` | true / false |
| `CollectedAtUtc` | Row timestamp — also the evidence that the run is a rolling snapshot |

Detail columns cost nothing at collection time: the API returns the full setting object in the
same response that answers the binary question. Deferring them would mean a second full scan.

---

## 10. Not collected: subscription and management group settings

Resource-level settings are not the whole picture. **Activity log export is configured at
subscription scope**, and management groups have their own API. Both are cheap — one call per
subscription plus a handful.

```http
GET https://management.azure.com/subscriptions/{subscriptionId}/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview
```

> Sources: [Diagnostic settings in Azure Monitor](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings),
> [Management Group Diagnostic Settings REST API](https://learn.microsoft.com/en-us/rest/api/monitor/management-group-diagnostic-settings)

Worth adding to any deliverable — customers are frequently surprised here. It is the most
obvious enhancement to this solution.
