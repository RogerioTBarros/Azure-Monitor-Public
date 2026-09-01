#Requires -Version 7.0

<#
.SYNOPSIS
    Tenant-wide inventory of Azure Monitor diagnostic settings, exported to CSV.

.DESCRIPTION
    Diagnostic settings are ARM extension resources and are NOT indexed by Azure Resource
    Graph, so they cannot be queried directly. This script therefore:

      1. Census  - counts resources by type and by subscription (Resource Graph, ~2 calls).
      2. Probe   - determines which resource types in THIS estate actually support
                   diagnostic settings, by calling diagnosticSettingsCategories against one
                   sample resource per type. Empirical, so no hardcoded type list to rot.
      3. Collect - reads diagnostic settings for every candidate resource through the ARM
                   batch endpoint, throttle-aware and resumable.
      4. Export  - writes a summary CSV (the reporting layout) and a detail CSV.

    Read-only. Makes no changes to the target tenant.

.NOTES
    Designed to run in Azure Cloud Shell (PowerShell mode), which is pre-authenticated.
    Only Az.Accounts is required - all calls go through Invoke-AzRestMethod, so there is
    no dependency on Az.ResourceGraph.

    Throttling model (ARM token bucket, 2024):
      Subscription reads: bucket 250, refill 25/sec - per subscription, PER SERVICE PRINCIPAL
      Tenant reads:       bucket 250, refill 25/sec
    https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/request-limits-and-throttling

    Defaults are deliberately conservative. Raise -TargetBatchesPerSecond only after a
    pilot run shows healthy headroom in the reported rate-limit figures.

.EXAMPLE
    ./Get-DiagnosticSettingsInventory.ps1 -ManagementGroupId 'contoso-root' -Phase Census
    Sizes the job before committing to a full run. Costs ~2 API calls.

.EXAMPLE
    ./Get-DiagnosticSettingsInventory.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000'
    Pilot against a single subscription.

.EXAMPLE
    ./Get-DiagnosticSettingsInventory.ps1 -ManagementGroupId 'contoso-root'
    Full run. Resumable - re-running skips subscriptions already completed.
#>

[CmdletBinding()]
param(
    # Management group to scope the inventory to. Covers every subscription beneath it.
    [string] $ManagementGroupId,

    # Explicit subscription list. Ignored when -ManagementGroupId is supplied.
    # Omit both to use every subscription the current identity can see.
    [string[]] $SubscriptionId,

    # Cloud Shell note: defaults to ./Data under the current directory, which is writable
    # and persists in clouddrive. Never default this to $PSScriptRoot/.. - see README.
    [string] $OutputDir = (Join-Path $PWD.Path 'Data'),

    [ValidateSet('All', 'Census', 'Probe', 'Collect', 'Export')]
    [string[]] $Phase = @('All'),

    # ARM batch sub-request count. 20 matches the value used by Azure Quick Review (azqr).
    [ValidateRange(1, 20)]
    [int] $BatchSize = 20,

    # Batch POSTs per second. At the default, 4 x 20 = 80 resources/sec.
    [ValidateRange(0.25, 20)]
    [double] $TargetBatchesPerSecond = 4,

    # Pause when reported remaining reads fall below this, rather than waiting for a 429.
    [int] $MinReadHeadroom = 100,

    [ValidateRange(1, 10)]
    [int] $MaxRetries = 5,

    # Restrict collection to specific resource types (case-insensitive).
    [string[]] $ResourceType,

    # Force-include types the probe reported as unsupported.
    [string[]] $AdditionalType,

    # Skip the support probe and query every type. Much higher ARM load - use sparingly.
    [switch] $IncludeAllTypes,

    # Opt out of expanding storage accounts into their blob/file/queue/table sub-resources.
    # Doing so leaves storage LOG settings uncollected - see the note in Invoke-CollectPhase.
    [switch] $SkipStorageServices,

    # Re-process subscriptions already marked complete.
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
# Version 1.0 only: catches uninitialised variables without throwing on the optional
# properties that ARM JSON payloads legitimately omit (workspaceId, eventHubName, ...).
Set-StrictMode -Version 1.0

# ----------------------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------------------

$script:ArmBase              = 'https://management.azure.com'
$script:BatchApiVersion      = '2020-06-01'
$script:DiagnosticApiVersion = '2021-05-01-preview'
$script:GraphApiVersion      = '2022-10-01'
$script:GraphPageSize        = 1000

# Resource Graph enforces its own quota (~15 queries per 5s per user), separate from the ARM
# read bucket, and each paged call costs one unit. Deliberately NOT $MinReadHeadroom - that
# default of 100 exceeds the entire ARG quota and would pause on every single response.
# https://learn.microsoft.com/en-us/azure/governance/resource-graph/concepts/guidance-for-throttled-requests
$script:MinGraphQuota        = 3

# Storage exposes only METRIC categories on the account itself; the log categories live on
# these service sub-resources, which Resource Graph does not index. Their IDs are
# deterministic ('<accountId>/<service>/default'), so they are synthesized rather than
# enumerated. Verified 2026-08-11: all four return HTTP 200 from diagnosticSettings.
$script:StorageServices      = @('blobServices', 'fileServices', 'queueServices', 'tableServices')

$script:Stats = [ordered]@{
    GraphQueries        = 0
    BatchRequests       = 0
    SingleRequests      = 0
    ProbeRequests       = 0
    Throttled429        = 0
    HeadroomPauses      = 0
    GraphQuotaPauses    = 0
    ResourcesProcessed  = 0
}

$script:LastRequestTicks = 0
$script:MinIntervalMs    = [int](1000 / $TargetBatchesPerSecond)

# ----------------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------------

function Write-Step {
    param([string] $Message, [string] $Level = 'INFO')
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $colour = switch ($Level) {
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'OK'    { 'Green' }
        default { 'Cyan' }
    }
    Write-Host "[$stamp] $Message" -ForegroundColor $colour
}

# HttpResponseHeaders enumerates as KeyValuePair<string, IEnumerable<string>>. Enumerating
# is safer than GetValues(), which throws when the header is absent.
function Get-HeaderValue {
    param($Response, [string] $Name)
    try {
        if (-not $Response -or -not $Response.Headers) { return $null }
        foreach ($header in $Response.Headers) {
            if ($header.Key -ieq $Name) { return @($header.Value)[0] }
        }
    }
    catch { }
    return $null
}

function Wait-ForPacing {
    if ($script:LastRequestTicks -gt 0) {
        $elapsedMs = [int](([datetime]::UtcNow.Ticks - $script:LastRequestTicks) / 10000)
        $waitMs = $script:MinIntervalMs - $elapsedMs
        if ($waitMs -gt 0) { Start-Sleep -Milliseconds $waitMs }
    }
    $script:LastRequestTicks = [datetime]::UtcNow.Ticks
}

<#
    Single entry point for every ARM call. Centralises pacing, 429 handling with
    Retry-After, proactive backoff on shrinking rate-limit headroom, and retry/backoff.
#>
function Invoke-ArmRequest {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [ValidateSet('GET', 'POST')] [string] $Method = 'GET',
        [string] $Payload,
        [switch] $AllowNotFound
    )

    $attempt = 0
    while ($true) {
        $attempt++
        Wait-ForPacing

        $response = $null
        $invokeError = $null
        try {
            if ($Method -eq 'POST') {
                $response = Invoke-AzRestMethod -Uri $Uri -Method POST -Payload $Payload -ErrorAction Stop
            }
            else {
                $response = Invoke-AzRestMethod -Uri $Uri -Method GET -ErrorAction Stop
            }
        }
        catch {
            $invokeError = $_
        }

        if ($response) {
            $status = [int] $response.StatusCode

            # Proactive backoff: react to shrinking headroom instead of waiting for a 429.
            foreach ($headerName in @('x-ms-ratelimit-remaining-subscription-reads',
                                      'x-ms-ratelimit-remaining-tenant-reads')) {
                $raw = Get-HeaderValue -Response $response -Name $headerName
                if ($raw) {
                    $remaining = 0
                    if ([int]::TryParse($raw, [ref] $remaining) -and $remaining -lt $MinReadHeadroom) {
                        $script:Stats.HeadroomPauses++
                        Write-Step "Rate-limit headroom low ($headerName = $remaining). Pausing 10s." 'WARN'
                        Start-Sleep -Seconds 10
                    }
                }
            }

            # Resource Graph quota is a separate bucket from the ARM read limits above, and is
            # only present on ARG responses. Paging a large estate exhausts it long before the
            # ARM bucket, so honour it explicitly rather than absorbing avoidable 429s.
            $quotaRaw = Get-HeaderValue -Response $response -Name 'x-ms-user-quota-remaining'
            if ($quotaRaw) {
                $quotaRemaining = 0
                if ([int]::TryParse($quotaRaw, [ref] $quotaRemaining) -and $quotaRemaining -lt $script:MinGraphQuota) {
                    $resetSeconds = 5
                    $resetRaw = Get-HeaderValue -Response $response -Name 'x-ms-user-quota-resets-after'
                    $resetSpan = [timespan]::Zero
                    if ($resetRaw -and [timespan]::TryParse($resetRaw, [ref] $resetSpan) -and $resetSpan.TotalSeconds -gt 0) {
                        $resetSeconds = [Math]::Ceiling($resetSpan.TotalSeconds)
                    }
                    $script:Stats.GraphQuotaPauses++
                    Write-Step "Resource Graph quota low (remaining = $quotaRemaining). Pausing ${resetSeconds}s." 'WARN'
                    Start-Sleep -Seconds $resetSeconds
                }
            }

            if ($status -eq 429 -or $status -ge 500) {
                if ($attempt -gt $MaxRetries) {
                    throw "ARM request failed after $MaxRetries retries (HTTP $status): $Uri"
                }
                if ($status -eq 429) { $script:Stats.Throttled429++ }

                $retryAfter = Get-HeaderValue -Response $response -Name 'Retry-After'
                $delay = 0
                if ($retryAfter -and [int]::TryParse($retryAfter, [ref] $delay) -and $delay -gt 0) {
                    Write-Step "HTTP $status - honouring Retry-After: ${delay}s (attempt $attempt)" 'WARN'
                }
                else {
                    $delay = [Math]::Min(60, [Math]::Pow(2, $attempt) * 2)
                    Write-Step "HTTP $status - backing off ${delay}s (attempt $attempt)" 'WARN'
                }
                Start-Sleep -Seconds $delay
                continue
            }

            if ($status -eq 404 -and $AllowNotFound) {
                return [pscustomobject]@{ StatusCode = $status; Content = $null }
            }

            return [pscustomobject]@{ StatusCode = $status; Content = $response.Content }
        }

        if ($attempt -gt $MaxRetries) {
            throw "ARM request failed after $MaxRetries attempts: $Uri`n$($invokeError.Exception.Message)"
        }
        $delay = [Math]::Min(60, [Math]::Pow(2, $attempt) * 2)
        Write-Step "Transport error - retrying in ${delay}s (attempt $attempt): $($invokeError.Exception.Message)" 'WARN'
        Start-Sleep -Seconds $delay
    }
}

<#
    Runs a Resource Graph query and pages through every result via $skipToken.
    Resource Graph has its own throttling bucket, separate from ARM provider reads.
#>
function Invoke-GraphQuery {
    param(
        [Parameter(Mandatory)] [string] $Query,
        [string[]] $Subscriptions,
        [string] $ManagementGroup
    )

    $uri = "$script:ArmBase/providers/Microsoft.ResourceGraph/resources?api-version=$script:GraphApiVersion"
    $results = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null

    while ($true) {
        $options = @{
            '$top'       = $script:GraphPageSize
            resultFormat = 'objectArray'
        }
        if ($skipToken) { $options['$skipToken'] = $skipToken }

        $body = @{ query = $Query; options = $options }
        if ($ManagementGroup) { $body['managementGroups'] = @($ManagementGroup) }
        elseif ($Subscriptions) { $body['subscriptions'] = [string[]] $Subscriptions }

        $payload = $body | ConvertTo-Json -Depth 10 -Compress
        $response = Invoke-ArmRequest -Uri $uri -Method POST -Payload $payload
        $script:Stats.GraphQueries++

        if ($response.StatusCode -ne 200) {
            throw "Resource Graph query failed (HTTP $($response.StatusCode)): $($response.Content)"
        }

        $parsed = $response.Content | ConvertFrom-Json -Depth 30
        if ($parsed.PSObject.Properties.Name -contains 'data' -and $parsed.data) {
            foreach ($row in $parsed.data) { $results.Add($row) }
        }

        $skipToken = $null
        if ($parsed.PSObject.Properties.Name -contains '$skipToken') { $skipToken = $parsed.'$skipToken' }
        if (-not $skipToken) { break }
    }

    return [object[]] $results.ToArray()
}

function Get-ScopeSplat {
    $splat = @{}
    if ($ManagementGroupId) { $splat['ManagementGroup'] = $ManagementGroupId }
    elseif ($SubscriptionId) { $splat['Subscriptions'] = $SubscriptionId }
    return $splat
}

# ----------------------------------------------------------------------------------------
# Phase 1 - Census
# ----------------------------------------------------------------------------------------

function Invoke-CensusPhase {
    Write-Step 'PHASE 1/4 - Census (Resource Graph, ~2 calls)'

    $scope = Get-ScopeSplat

    $byType = Invoke-GraphQuery -Query @'
resources
| summarize ResourceCount = count() by type
| order by ResourceCount desc
'@ @scope

    $bySub = Invoke-GraphQuery -Query @'
resources
| summarize ResourceCount = count() by subscriptionId
| order by ResourceCount desc
'@ @scope

    $typePath = Join-Path $OutputDir 'census-by-type.csv'
    $subPath  = Join-Path $OutputDir 'census-by-subscription.csv'

    $byType | Select-Object type, ResourceCount | Export-Csv -Path $typePath -NoTypeInformation -Encoding utf8
    $bySub  | Select-Object subscriptionId, ResourceCount | Export-Csv -Path $subPath -NoTypeInformation -Encoding utf8

    $totalResources = ($byType | Measure-Object -Property ResourceCount -Sum).Sum
    $largestSub = $bySub | Select-Object -First 1

    Write-Step "Distinct resource types : $($byType.Count)" 'OK'
    Write-Step "Subscriptions in scope  : $($bySub.Count)" 'OK'
    Write-Step "Total resources         : $totalResources" 'OK'
    if ($largestSub) {
        Write-Step "Largest subscription    : $($largestSub.subscriptionId) ($($largestSub.ResourceCount) resources)" 'OK'
    }
    Write-Step "Written: $typePath"
    Write-Step "Written: $subPath"
}

# ----------------------------------------------------------------------------------------
# Phase 2 - Probe which types support diagnostic settings
# ----------------------------------------------------------------------------------------

function Invoke-ProbePhase {
    Write-Step 'PHASE 2/4 - Probing resource types for diagnostic settings support'

    $probePath = Join-Path $OutputDir 'supported-types.csv'
    if ((Test-Path $probePath) -and -not $Force) {
        Write-Step "Reusing cached probe results: $probePath (use -Force to re-probe)"
        return Import-Csv -Path $probePath
    }

    $scope = Get-ScopeSplat

    # make_list(id, 1) yields one sample resource ID per type in a single query.
    $samples = Invoke-GraphQuery -Query @'
resources
| summarize ResourceCount = count(), SampleIds = make_list(id, 1) by type
| order by ResourceCount desc
'@ @scope

    Write-Step "Probing $($samples.Count) distinct resource types (1 call each)"

    $probeResults = [System.Collections.Generic.List[object]]::new()
    $index = 0

    foreach ($sample in $samples) {
        $index++
        $sampleId = $null
        if ($sample.SampleIds -and @($sample.SampleIds).Count -gt 0) { $sampleId = @($sample.SampleIds)[0] }

        $supported      = $false
        $categories     = ''
        $status         = 0
        $settingsStatus = 0
        $reason         = ''

        if ($sampleId) {
            try {
                $catUri = "$script:ArmBase$sampleId/providers/Microsoft.Insights/diagnosticSettingsCategories?api-version=$script:DiagnosticApiVersion"
                $response = Invoke-ArmRequest -Uri $catUri -Method GET -AllowNotFound
                $script:Stats.ProbeRequests++
                $status = $response.StatusCode

                if ($status -eq 200 -and $response.Content) {
                    $parsed = $response.Content | ConvertFrom-Json -Depth 20
                    if ($parsed.PSObject.Properties.Name -contains 'value' -and $parsed.value) {
                        $names = @($parsed.value | ForEach-Object { $_.name })
                        if ($names.Count -gt 0) { $categories = ($names -join ';') }
                    }
                }

                # A 200 from diagnosticSettingsCategories does NOT imply the diagnosticSettings
                # endpoint accepts the type. Metrics-only types return AllMetrics here and still
                # fail with 400 ResourceTypeNotSupported on the read the collector performs, so
                # support is decided by the endpoint that actually matters.
                $setUri = "$script:ArmBase$sampleId/providers/microsoft.insights/diagnosticSettings?api-version=$script:DiagnosticApiVersion"
                $setResponse = Invoke-ArmRequest -Uri $setUri -Method GET -AllowNotFound
                $script:Stats.ProbeRequests++
                $settingsStatus = $setResponse.StatusCode
                $supported = ($settingsStatus -eq 200)

                if (-not $supported -and $setResponse.Content -and $setResponse.Content -match '"code"\s*:\s*"([^"]+)"') {
                    $reason = $Matches[1]
                }
            }
            catch {
                $status = -1
                Write-Step "Probe failed for $($sample.type): $($_.Exception.Message)" 'WARN'
            }
        }

        $probeResults.Add([pscustomobject]@{
            ResourceType        = $sample.type
            Supported           = $supported
            ResourceCount       = $sample.ResourceCount
            Categories          = $categories
            ProbeStatus         = $status
            SettingsProbeStatus = $settingsStatus
            SupportReason       = $reason
            SampleId            = $sampleId
        })

        if ($index % 25 -eq 0) { Write-Step "  probed $index / $($samples.Count)" }
    }

    $output = [object[]] $probeResults.ToArray()
    $output | Export-Csv -Path $probePath -NoTypeInformation -Encoding utf8

    $supportedCount = @($output | Where-Object { [bool]::Parse([string]$_.Supported) }).Count
    $candidateCount = ($output | Where-Object { [bool]::Parse([string]$_.Supported) } |
                       Measure-Object -Property ResourceCount -Sum).Sum

    Write-Step "Types supporting diagnostic settings : $supportedCount / $($output.Count)" 'OK'
    Write-Step "Candidate resources to collect       : $candidateCount" 'OK'
    Write-Step "Written: $probePath"
    Write-Step 'Review supported-types.csv before the full run - anything wrongly excluded can be re-added with -AdditionalType.' 'WARN'

    return $output
}

# ----------------------------------------------------------------------------------------
# Phase 3 - Collect
# ----------------------------------------------------------------------------------------

function Get-DiagnosticSettingsForBatch {
    param([Parameter(Mandatory)] [object[]] $Resources)

    $requests = [System.Collections.Generic.List[object]]::new()
    foreach ($resource in $Resources) {
        $requests.Add([pscustomobject]@{
            httpMethod  = 'GET'
            relativeUrl = "$($resource.id)/providers/microsoft.insights/diagnosticSettings?api-version=$script:DiagnosticApiVersion"
        })
    }

    $payload = @{ requests = [object[]] $requests.ToArray() } | ConvertTo-Json -Depth 10 -Compress
    $uri = "$script:ArmBase/batch?api-version=$script:BatchApiVersion"

    $response = Invoke-ArmRequest -Uri $uri -Method POST -Payload $payload
    $script:Stats.BatchRequests++

    if ($response.StatusCode -ne 200) {
        throw "Batch request failed (HTTP $($response.StatusCode)): $($response.Content)"
    }

    $parsed = $response.Content | ConvertFrom-Json -Depth 40

    # The batch response is not guaranteed to preserve request order, so settings are
    # attributed by parsing each returned setting's own resource ID rather than by index.
    $settingsByResource = @{}
    $anyFailure = $false

    if ($parsed.PSObject.Properties.Name -contains 'responses' -and $parsed.responses) {
        foreach ($item in $parsed.responses) {
            $itemProps = $item.PSObject.Properties.Name
            if ($itemProps -notcontains 'httpStatusCode') { $anyFailure = $true; continue }
            if ([int]$item.httpStatusCode -ne 200) { $anyFailure = $true; continue }
            if ($itemProps -notcontains 'content' -or -not $item.content) { continue }
            if (-not ($item.content.PSObject.Properties.Name -contains 'value')) { continue }

            foreach ($setting in @($item.content.value)) {
                if ($setting.PSObject.Properties.Name -notcontains 'id' -or -not $setting.id) { continue }
                $marker = '/providers/microsoft.insights/diagnosticsettings/'
                $cut = $setting.id.ToLowerInvariant().IndexOf($marker)
                if ($cut -lt 0) { continue }
                $parentId = $setting.id.Substring(0, $cut).ToLowerInvariant()

                if (-not $settingsByResource.ContainsKey($parentId)) {
                    $settingsByResource[$parentId] = [System.Collections.Generic.List[object]]::new()
                }
                $settingsByResource[$parentId].Add($setting)
            }
        }
    }

    return [pscustomobject]@{
        SettingsByResource = $settingsByResource
        AnyFailure         = $anyFailure
    }
}

# Individual fallback, used only for batches that returned at least one non-200, so that
# 403/404 can be attributed to the exact resource instead of being lost in the batch.
function Get-DiagnosticSettingsSingle {
    param([Parameter(Mandatory)] $Resource)

    $uri = "$script:ArmBase$($Resource.id)/providers/Microsoft.Insights/diagnosticSettings?api-version=$script:DiagnosticApiVersion"
    try {
        $response = Invoke-ArmRequest -Uri $uri -Method GET -AllowNotFound
        $script:Stats.SingleRequests++

        if ($response.StatusCode -eq 200 -and $response.Content) {
            $parsed = $response.Content | ConvertFrom-Json -Depth 30
            $values = @()
            if ($parsed.PSObject.Properties.Name -contains 'value' -and $parsed.value) { $values = @($parsed.value) }
            return [pscustomobject]@{ Status = 'OK'; Settings = $values }
        }
        if ($response.StatusCode -eq 403) { return [pscustomobject]@{ Status = 'AccessDenied'; Settings = @() } }
        if ($response.StatusCode -eq 404) { return [pscustomobject]@{ Status = 'NotFound'; Settings = @() } }
        # Distinct from Error: the type genuinely cannot carry diagnostic settings.
        if ($response.StatusCode -eq 400 -and $response.Content -and $response.Content -match 'ResourceTypeNotSupported') {
            return [pscustomobject]@{ Status = 'NotSupported'; Settings = @() }
        }
        return [pscustomobject]@{ Status = "Error$($response.StatusCode)"; Settings = @() }
    }
    catch {
        return [pscustomobject]@{ Status = 'Error'; Settings = @() }
    }
}

function ConvertTo-InventoryRow {
    param(
        [Parameter(Mandatory)] $Resource,
        [object[]] $Settings = @(),
        [string] $Status = 'OK',
        [hashtable] $SubscriptionNames = @{}
    )

    $settingArray = @($Settings)
    $destinations = [System.Collections.Generic.List[string]]::new()
    $workspaces   = [System.Collections.Generic.List[string]]::new()
    $storage      = [System.Collections.Generic.List[string]]::new()
    $eventHubs    = [System.Collections.Generic.List[string]]::new()
    $categories   = [System.Collections.Generic.List[string]]::new()
    $names        = [System.Collections.Generic.List[string]]::new()
    $metricsOn    = $false

    foreach ($setting in $settingArray) {
        if ($setting.PSObject.Properties.Name -contains 'name' -and $setting.name) { $names.Add([string]$setting.name) }
        if ($setting.PSObject.Properties.Name -notcontains 'properties') { continue }
        $props = $setting.properties
        if (-not $props) { continue }

        if ($props.PSObject.Properties.Name -contains 'workspaceId' -and $props.workspaceId) {
            $destinations.Add('LogAnalytics'); $workspaces.Add([string]$props.workspaceId)
        }
        if ($props.PSObject.Properties.Name -contains 'storageAccountId' -and $props.storageAccountId) {
            $destinations.Add('Storage'); $storage.Add([string]$props.storageAccountId)
        }
        if ($props.PSObject.Properties.Name -contains 'eventHubAuthorizationRuleId' -and $props.eventHubAuthorizationRuleId) {
            $destinations.Add('EventHub')
            $hubName = if ($props.PSObject.Properties.Name -contains 'eventHubName' -and $props.eventHubName) { [string]$props.eventHubName } else { '(default)' }
            $eventHubs.Add($hubName)
        }
        if ($props.PSObject.Properties.Name -contains 'marketplacePartnerId' -and $props.marketplacePartnerId) {
            $destinations.Add('Partner')
        }
        if ($props.PSObject.Properties.Name -contains 'logs' -and $props.logs) {
            foreach ($log in @($props.logs)) {
                $logProps = $log.PSObject.Properties.Name
                if ($logProps -notcontains 'enabled' -or -not $log.enabled) { continue }
                if ($logProps -contains 'categoryGroup' -and $log.categoryGroup) { $categories.Add([string]$log.categoryGroup) }
                elseif ($logProps -contains 'category' -and $log.category) { $categories.Add([string]$log.category) }
            }
        }
        if ($props.PSObject.Properties.Name -contains 'metrics' -and $props.metrics) {
            foreach ($metric in @($props.metrics)) {
                if ($metric.PSObject.Properties.Name -contains 'enabled' -and $metric.enabled) { $metricsOn = $true }
            }
        }
    }

    $diagnosticStatus = switch ($Status) {
        'OK'           { if ($settingArray.Count -gt 0) { 'Enabled' } else { 'NotConfigured' } }
        'AccessDenied' { 'AccessDenied' }
        'NotFound'     { 'NotFound' }
        'NotSupported' { 'NotSupported' }
        default        { 'Error' }
    }

    $subName = ''
    if ($Resource.subscriptionId -and $SubscriptionNames.ContainsKey($Resource.subscriptionId)) {
        $subName = $SubscriptionNames[$Resource.subscriptionId]
    }

    return [pscustomobject]@{
        SubscriptionId    = $Resource.subscriptionId
        SubscriptionName  = $subName
        ResourceGroup     = $Resource.resourceGroup
        ResourceName      = $Resource.name
        ResourceType      = $Resource.type
        Location          = $Resource.location
        ResourceId        = $Resource.id
        DiagnosticStatus  = $diagnosticStatus
        SettingsCount     = $settingArray.Count
        SettingNames      = (($names            | Select-Object -Unique) -join ';')
        DestinationTypes  = (($destinations     | Select-Object -Unique) -join ';')
        WorkspaceIds      = (($workspaces       | Select-Object -Unique) -join ';')
        StorageAccountIds = (($storage          | Select-Object -Unique) -join ';')
        EventHubNames     = (($eventHubs        | Select-Object -Unique) -join ';')
        LogCategories     = (($categories       | Select-Object -Unique) -join ';')
        MetricsEnabled    = $metricsOn
        CollectedAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Invoke-CollectPhase {
    param([object[]] $ProbeResults)

    Write-Step 'PHASE 3/4 - Collecting diagnostic settings'

    $checkpointDir = Join-Path $OutputDir 'checkpoints'
    if (-not (Test-Path $checkpointDir)) { New-Item -ItemType Directory -Path $checkpointDir -Force | Out-Null }

    # Build the candidate type list.
    $typeFilter = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($IncludeAllTypes) {
        Write-Step 'IncludeAllTypes set - querying every resource type. Expect substantially higher ARM load.' 'WARN'
    }
    else {
        foreach ($row in $ProbeResults) {
            if ([bool]::Parse([string]$row.Supported)) { [void] $typeFilter.Add([string]$row.ResourceType) }
        }
    }
    foreach ($extra in $AdditionalType) { [void] $typeFilter.Add($extra) }
    if ($ResourceType) {
        $explicit = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($t in $ResourceType) { [void] $explicit.Add($t) }
        $typeFilter = $explicit
    }

    if (-not $IncludeAllTypes -and $typeFilter.Count -eq 0) {
        throw 'No candidate resource types selected. Run the Probe phase first, or pass -ResourceType / -IncludeAllTypes.'
    }

    # Resolve subscription display names for the CSV.
    $scope = Get-ScopeSplat
    $subscriptionNames = @{}
    try {
        $containers = Invoke-GraphQuery -Query @'
resourcecontainers
| where type =~ 'microsoft.resources/subscriptions'
| project subscriptionId, name
'@ @scope
        foreach ($container in $containers) { $subscriptionNames[$container.subscriptionId] = $container.name }
    }
    catch {
        Write-Step "Could not resolve subscription names: $($_.Exception.Message)" 'WARN'
    }

    # Enumerate candidate resources.
    Write-Step 'Enumerating candidate resources via Resource Graph'
    if ($IncludeAllTypes) {
        $query = @'
resources
| project id, name, type, resourceGroup, subscriptionId, location
| order by id asc
'@
    }
    else {
        $typeList = ($typeFilter | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
        $query = @"
resources
| where type in~ ($typeList)
| project id, name, type, resourceGroup, subscriptionId, location
| order by id asc
"@
    }

    $candidates = Invoke-GraphQuery -Query $query @scope
    Write-Step "Candidate resources: $($candidates.Count)" 'OK'
    if ($candidates.Count -eq 0) { Write-Step 'Nothing to collect.' 'WARN'; return }

    if (-not $SkipStorageServices) {
        $storageAccounts = @($candidates | Where-Object { [string]$_.type -ieq 'microsoft.storage/storageaccounts' })
        if ($storageAccounts.Count -gt 0) {
            $expanded = [System.Collections.Generic.List[object]]::new()
            foreach ($account in $storageAccounts) {
                foreach ($service in $script:StorageServices) {
                    $expanded.Add([pscustomobject]@{
                        id             = "$($account.id)/$service/default"
                        name           = "$($account.name)/$service"
                        type           = "microsoft.storage/storageaccounts/$($service.ToLowerInvariant())"
                        resourceGroup  = $account.resourceGroup
                        subscriptionId = $account.subscriptionId
                        location       = $account.location
                    })
                }
            }
            $candidates = [object[]] ($candidates + $expanded.ToArray())
            Write-Step "Expanded $($storageAccounts.Count) storage accounts into $($expanded.Count) service sub-resources" 'OK'
            Write-Step "Candidate resources after expansion: $($candidates.Count)" 'OK'
        }
    }

    $bySubscription = $candidates | Group-Object -Property subscriptionId
    $subIndex = 0

    foreach ($group in $bySubscription) {
        $subIndex++
        $subId = $group.Name
        $doneMarker = Join-Path $checkpointDir "$subId.done"
        $checkpointFile = Join-Path $checkpointDir "$subId.jsonl"

        if ((Test-Path $doneMarker) -and -not $Force) {
            Write-Step "[$subIndex/$($bySubscription.Count)] $subId - already complete, skipping"
            continue
        }

        # Resume support: skip resources already written to the checkpoint.
        $processed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        if ((Test-Path $checkpointFile) -and -not $Force) {
            foreach ($line in (Get-Content -Path $checkpointFile)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { [void] $processed.Add(($line | ConvertFrom-Json -Depth 10).ResourceId) } catch { }
            }
        }
        elseif ($Force -and (Test-Path $checkpointFile)) {
            Remove-Item -Path $checkpointFile -Force
        }

        $pending = @($group.Group | Where-Object { -not $processed.Contains([string]$_.id) })
        Write-Step "[$subIndex/$($bySubscription.Count)] $subId - $($pending.Count) to process ($($processed.Count) already done)"
        if ($pending.Count -eq 0) { New-Item -ItemType File -Path $doneMarker -Force | Out-Null; continue }

        for ($offset = 0; $offset -lt $pending.Count; $offset += $BatchSize) {
            $take = [Math]::Min($BatchSize, $pending.Count - $offset)
            $chunk = [object[]] $pending[$offset..($offset + $take - 1)]

            $batchResult = Get-DiagnosticSettingsForBatch -Resources $chunk
            $rows = [System.Collections.Generic.List[object]]::new()

            foreach ($resource in $chunk) {
                $key = ([string]$resource.id).ToLowerInvariant()
                if ($batchResult.SettingsByResource.ContainsKey($key)) {
                    $settings = [object[]] $batchResult.SettingsByResource[$key].ToArray()
                    $rows.Add((ConvertTo-InventoryRow -Resource $resource -Settings $settings -Status 'OK' -SubscriptionNames $subscriptionNames))
                }
                elseif ($batchResult.AnyFailure) {
                    # Attribute the failure precisely rather than mislabelling it NotConfigured.
                    $single = Get-DiagnosticSettingsSingle -Resource $resource
                    $rows.Add((ConvertTo-InventoryRow -Resource $resource -Settings $single.Settings -Status $single.Status -SubscriptionNames $subscriptionNames))
                }
                else {
                    $rows.Add((ConvertTo-InventoryRow -Resource $resource -Settings @() -Status 'OK' -SubscriptionNames $subscriptionNames))
                }
            }

            $lines = foreach ($row in $rows) { $row | ConvertTo-Json -Depth 10 -Compress }
            Add-Content -Path $checkpointFile -Value $lines -Encoding utf8

            $script:Stats.ResourcesProcessed += $chunk.Count
            $done = [Math]::Min($offset + $take, $pending.Count)
            if (($offset / $BatchSize) % 25 -eq 0 -or $done -eq $pending.Count) {
                Write-Step "    $done / $($pending.Count)"
            }
        }

        New-Item -ItemType File -Path $doneMarker -Force | Out-Null
    }
}

# ----------------------------------------------------------------------------------------
# Phase 4 - Export
# ----------------------------------------------------------------------------------------

function Invoke-ExportPhase {
    Write-Step 'PHASE 4/4 - Export'

    $checkpointDir = Join-Path $OutputDir 'checkpoints'
    if (-not (Test-Path $checkpointDir)) { Write-Step 'No checkpoints found - nothing to export.' 'WARN'; return }

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -Path $checkpointDir -Filter '*.jsonl') {
        foreach ($line in (Get-Content -Path $file.FullName)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $rows.Add(($line | ConvertFrom-Json -Depth 10)) } catch { }
        }
    }

    if ($rows.Count -eq 0) { Write-Step 'No rows to export.' 'WARN'; return }

    $all = [object[]] $rows.ToArray()

    # Detail export - every column.
    $detailPath = Join-Path $OutputDir 'diagnostic-settings-detail.csv'
    $all | Export-Csv -Path $detailPath -NoTypeInformation -Encoding utf8

    # Summary export - the reporting layout.
    $summaryPath = Join-Path $OutputDir 'diagnostic-settings-summary.csv'
    $all |
        Select-Object SubscriptionName, SubscriptionId, ResourceGroup, ResourceType, ResourceName, DiagnosticStatus |
        Sort-Object SubscriptionName, ResourceGroup, ResourceType, ResourceName |
        Export-Csv -Path $summaryPath -NoTypeInformation -Encoding utf8

    # Rollup by subscription and type.
    $rollupPath = Join-Path $OutputDir 'diagnostic-settings-rollup.csv'
    $all |
        Group-Object SubscriptionId, ResourceType |
        ForEach-Object {
            $members = $_.Group
            [pscustomobject]@{
                SubscriptionId = $members[0].SubscriptionId
                SubscriptionName = $members[0].SubscriptionName
                ResourceType   = $members[0].ResourceType
                Total          = $members.Count
                Enabled        = @($members | Where-Object DiagnosticStatus -eq 'Enabled').Count
                NotConfigured  = @($members | Where-Object DiagnosticStatus -eq 'NotConfigured').Count
                Other          = @($members | Where-Object { $_.DiagnosticStatus -notin @('Enabled', 'NotConfigured') }).Count
            }
        } |
        Sort-Object SubscriptionName, ResourceType |
        Export-Csv -Path $rollupPath -NoTypeInformation -Encoding utf8

    $enabled = @($all | Where-Object DiagnosticStatus -eq 'Enabled').Count
    $notConfigured = @($all | Where-Object DiagnosticStatus -eq 'NotConfigured').Count
    $other = $all.Count - $enabled - $notConfigured

    Write-Step "Total resources : $($all.Count)" 'OK'
    Write-Step "Enabled         : $enabled" 'OK'
    Write-Step "Not configured  : $notConfigured" 'OK'
    if ($other -gt 0) { Write-Step "Other statuses  : $other (see detail CSV)" 'WARN' }
    Write-Step "Written: $summaryPath"
    Write-Step "Written: $detailPath"
    Write-Step "Written: $rollupPath"
}

# ----------------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------------

$started = Get-Date

$context = Get-AzContext
if (-not $context) { throw 'No Azure context. Run Connect-AzAccount first (not required in Cloud Shell).' }
Write-Step "Account : $($context.Account.Id)"
Write-Step "Tenant  : $($context.Tenant.Id)"

if ($ManagementGroupId)  { Write-Step "Scope   : management group '$ManagementGroupId'" }
elseif ($SubscriptionId) { Write-Step "Scope   : $($SubscriptionId.Count) explicit subscription(s)" }
else                     { Write-Step 'Scope   : all accessible subscriptions' 'WARN' }

Write-Step "Pacing  : $TargetBatchesPerSecond batch/sec x $BatchSize per batch = ~$([int]($TargetBatchesPerSecond * $BatchSize)) resources/sec"

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
Write-Step "Output  : $OutputDir"

$runAll = $Phase -contains 'All'
$probeResults = @()

if ($runAll -or $Phase -contains 'Census')  { Invoke-CensusPhase }
if ($runAll -or $Phase -contains 'Probe')   { $probeResults = Invoke-ProbePhase }

if ($runAll -or $Phase -contains 'Collect') {
    if (-not $probeResults -or @($probeResults).Count -eq 0) {
        $probePath = Join-Path $OutputDir 'supported-types.csv'
        if (Test-Path $probePath) { $probeResults = Import-Csv -Path $probePath }
    }
    Invoke-CollectPhase -ProbeResults ([object[]] $probeResults)
}

if ($runAll -or $Phase -contains 'Export')  { Invoke-ExportPhase }

$elapsed = (Get-Date) - $started
Write-Step '--- Run summary ---' 'OK'
foreach ($entry in $script:Stats.GetEnumerator()) { Write-Step ("  {0,-20} {1}" -f $entry.Key, $entry.Value) }
Write-Step ("  {0,-20} {1:hh\:mm\:ss}" -f 'Elapsed', $elapsed) 'OK'
