#Requires -Version 7.0

<#
.SYNOPSIS
    Driver for Get-DiagnosticSettingsInventory.ps1 that collects one subscription per OS process.

.DESCRIPTION
    On large estates, a single long-running collection process degrades progressively: batch
    round-trips grow from seconds to minutes and the process eventually stalls, even though a
    freshly started process answers the same request immediately. The cause is state that
    accumulates inside the process (sockets/handles), not ARM latency and not throttling.

    This driver sidesteps that entirely by giving every subscription its own short-lived OS
    process with a hard timeout. If one subscription stalls, only that attempt is lost - the
    collector checkpoints after every batch, so the retry resumes where it stopped.

    Safe to re-run. Subscriptions already marked complete are skipped, and -Force is never
    passed to the collector (it would discard every checkpoint).

.NOTES
    Requires a completed Census and Probe at the FULL intended scope before it runs, because
    the Collect phase reuses the cached supported-types.csv.

.EXAMPLE
    ./Invoke-DiagnosticSettingsCollection.ps1

    Collects every subscription listed in Data/census-by-subscription.csv.

.EXAMPLE
    ./Invoke-DiagnosticSettingsCollection.ps1 -BackupPath ~/dsi-progress.zip

    Same, refreshing a progress archive after each subscription completes.
#>

[CmdletBinding()]
param(
    # The collector. Defaults to a sibling file, which also works when both are uploaded to $HOME.
    [string] $ScriptPath = (Join-Path $PSScriptRoot 'Get-DiagnosticSettingsInventory.ps1'),

    # Must match the -OutputDir used for Census and Probe.
    [string] $OutputDir = (Join-Path $PWD.Path 'Data'),

    # Explicit subscription list. Defaults to every subscription in census-by-subscription.csv.
    [string[]] $SubscriptionId,

    # Hard ceiling per attempt. A stalled process is killed and retried rather than hanging the run.
    [ValidateRange(60, 7200)]
    [int] $TimeoutSeconds = 600,

    [ValidateRange(1, 50)]
    [int] $MaxAttempts = 20,

    # Optional .zip refreshed after each subscription. Essential on ephemeral Cloud Shell storage.
    [string] $BackupPath,

    [ValidateRange(0.25, 20)]
    [double] $TargetBatchesPerSecond = 4,

    [switch] $SkipStorageServices
)

$ErrorActionPreference = 'Stop'

function Write-Driver {
    param([string] $Message, [string] $Level = 'INFO')
    $colour = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Cyan' } }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $colour
}

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Collector not found at '$ScriptPath'. Pass -ScriptPath explicitly."
}
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path

# Fail early on a stale upload rather than after hours of plausible-looking output.
$collectorParams = (Get-Command $ScriptPath).Parameters.Keys
if ($collectorParams -notcontains 'SkipStorageServices') {
    throw "The collector at '$ScriptPath' is an outdated copy (no -SkipStorageServices parameter). Re-upload it."
}

$checkpointDir = Join-Path $OutputDir 'checkpoints'
if (-not (Test-Path -LiteralPath $checkpointDir)) {
    New-Item -ItemType Directory -Path $checkpointDir -Force | Out-Null
}

if (-not $SubscriptionId) {
    $censusPath = Join-Path $OutputDir 'census-by-subscription.csv'
    if (-not (Test-Path -LiteralPath $censusPath)) {
        throw "No -SubscriptionId given and '$censusPath' does not exist. Run -Phase Census first."
    }
    $SubscriptionId = @(Import-Csv -LiteralPath $censusPath | Select-Object -ExpandProperty subscriptionId)
}

$SubscriptionId = @($SubscriptionId | Where-Object { $_ } | Select-Object -Unique)
if ($SubscriptionId.Count -eq 0) { throw 'No subscriptions to process.' }

# Reuse the running host so the child is the same PowerShell build.
$pwshPath = (Get-Process -Id $PID).Path
if (-not $pwshPath) { $pwshPath = 'pwsh' }

# Invariant culture: a comma decimal separator would be rejected by the child's [double] parameter.
$pacing = $TargetBatchesPerSecond.ToString([System.Globalization.CultureInfo]::InvariantCulture)

Write-Driver "Collector    : $ScriptPath"
Write-Driver "Output       : $OutputDir"
Write-Driver "Subscriptions: $($SubscriptionId.Count)"
Write-Driver "Timeout      : ${TimeoutSeconds}s per attempt, up to $MaxAttempts attempts"

$completed = [System.Collections.Generic.List[string]]::new()
$exhausted = [System.Collections.Generic.List[string]]::new()
$index = 0
$started = Get-Date

foreach ($sub in $SubscriptionId) {
    $index++
    $prefix = "[$index/$($SubscriptionId.Count)] $sub"
    $doneMarker = Join-Path $checkpointDir "$sub.done"

    if (Test-Path -LiteralPath $doneMarker) {
        Write-Driver "$prefix - already complete, skipping"
        $completed.Add($sub)
        continue
    }

    $attempt = 0
    while (-not (Test-Path -LiteralPath $doneMarker) -and $attempt -lt $MaxAttempts) {
        $attempt++
        Write-Driver "$prefix - attempt $attempt of $MaxAttempts"

        # -Force is deliberately never passed: it would delete existing checkpoints.
        $childArgs = @(
            '-NoProfile'
            '-NonInteractive'
            '-File', $ScriptPath
            '-SubscriptionId', $sub
            '-Phase', 'Collect'
            '-OutputDir', $OutputDir
            '-TargetBatchesPerSecond', $pacing
        )
        if ($SkipStorageServices) { $childArgs += '-SkipStorageServices' }

        $process = Start-Process -FilePath $pwshPath -ArgumentList $childArgs -NoNewWindow -PassThru
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Write-Driver "$prefix - attempt $attempt exceeded ${TimeoutSeconds}s, terminating; progress is checkpointed" 'WARN'
            try { $process.Kill($true) } catch { Write-Driver "  could not terminate PID $($process.Id): $($_.Exception.Message)" 'WARN' }
            try { $null = $process.WaitForExit(30000) } catch { }
        }
        elseif ($process.ExitCode -ne 0) {
            Write-Driver "$prefix - attempt $attempt exited with code $($process.ExitCode)" 'WARN'
        }
    }

    if (Test-Path -LiteralPath $doneMarker) {
        Write-Driver "$prefix - complete" 'OK'
        $completed.Add($sub)
    }
    else {
        Write-Driver "$prefix - NOT complete after $MaxAttempts attempts; investigate before exporting" 'ERROR'
        $exhausted.Add($sub)
    }

    if ($BackupPath) {
        try {
            Compress-Archive -Path $checkpointDir -DestinationPath $BackupPath -Force
            Write-Driver "  progress archived to $BackupPath"
        }
        catch {
            Write-Driver "  backup failed: $($_.Exception.Message)" 'WARN'
        }
    }
}

$elapsed = (Get-Date) - $started
Write-Driver '--- Driver summary ---' 'OK'
Write-Driver ("  {0,-14} {1}" -f 'Completed', $completed.Count) 'OK'
Write-Driver ("  {0,-14} {1}" -f 'Incomplete', $exhausted.Count) $(if ($exhausted.Count) { 'ERROR' } else { 'OK' })
Write-Driver ("  {0,-14} {1:hh\:mm\:ss}" -f 'Elapsed', $elapsed) 'OK'

if ($exhausted.Count -gt 0) {
    Write-Driver 'Incomplete subscriptions:' 'ERROR'
    foreach ($sub in $exhausted) { Write-Driver "  $sub" 'ERROR' }
    Write-Driver 'Exporting now would produce a partial inventory.' 'WARN'
}
else {
    Write-Driver 'All subscriptions complete. Run -Phase Export to produce the CSVs.' 'OK'
}
