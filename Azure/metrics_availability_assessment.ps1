<#
.SYNOPSIS
    Collects VM performance metrics and availability data across all Azure subscriptions

.DESCRIPTION
    Outputs to flat **CSV files**
    - VM_Metrics_yyyyMMdd_HHmmss.csv
    - VM_Availability_yyyyMMdd_HHmmss.csv  (only if -IncludeAvailability)
    Rows are also appended to a matching .partial.csv as each batch of VMs finishes, so a run
    that stops part-way still leaves the rows collected so far.

.PARAMETER DaysBack
    Number of days to look back for metrics (default: 90, to catch month- and quarter-end peaks)
    Note: Azure Monitor keeps platform metrics for 93 days and returns at most 31 days per
    query, so longer windows are fetched in 30-day chunks.

.PARAMETER ThrottleLimit
    Number of VMs whose metrics are fetched at the same time (default: 8). Use 1 to fetch one
    VM at a time, e.g. if Azure Monitor throttles the requests.

.PARAMETER OutputPath
    Path for the output CSV files (default: current directory)

.PARAMETER IncludeAvailability
    Switch to include availability metrics collection

.PARAMETER TenantId
    Optional Azure Tenant ID to filter subscriptions.
    When not specified, uses current context tenant.

.PARAMETER SubscriptionIds
    Optional array of subscription IDs to process. When not specified, every enabled
    subscription in the tenant is processed. Use it to split a large tenant into several runs.

.PARAMETER VMNames
    Optional array of VM names to filter. When not specified, all VMs in scope are processed.

.PARAMETER UseDeviceAuthentication
    Use device-code login instead of opening a browser.
    Recommended for headless Linux, SSH sessions, or any environment without a desktop browser.

.PARAMETER SkipModuleCheck
    Skip the automatic install/import of required Az modules. Use only when you have already
    imported Az.Accounts, Az.Compute, and Az.Monitor in the current session.

.EXAMPLE
    # macOS / Linux / Windows (PowerShell 7+):
    pwsh -File ./metrics_availability_assessment.ps1 -DaysBack 30 -IncludeAvailability   # shorter window, faster run

.EXAMPLE
    # Headless server (no browser):
    pwsh -File ./metrics_availability_assessment.ps1 -UseDeviceAuthentication

.NOTES
    Author: Crayon Group
    Date: November 2026
    Version: 2.5 (retries without dropping metrics, MetricGaps column, flat memory, partial CSV)
    Runs on: Windows, macOS, Linux with PowerShell 7+
    Modules: Az.Accounts, Az.Compute, Az.Monitor (auto-installed for the current user if missing)
#>

#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 90)]
    [int]$DaysBack = 90,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 32)]
    [int]$ThrottleLimit = 8,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = $PWD.Path,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeAvailability,

    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [string[]]$VMNames,

    [Parameter(Mandatory = $false)]
    [switch]$UseDeviceAuthentication,

    [Parameter(Mandatory = $false)]
    [switch]$SkipModuleCheck
)

# AppLocker / WDAC can force Constrained Language mode, in which the script cannot create the
# .NET types it uses; say so up front rather than fail later with "Cannot create type".
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Error ("PowerShell is running in $($ExecutionContext.SessionState.LanguageMode) mode, which an AppLocker or WDAC policy on this machine sets. " +
        "The script needs FullLanguage mode: run it from a machine or account without that policy (see Troubleshooting in the README).")
    exit 1
}

# pwsh -File passes "-SubscriptionIds a,b" as the single string "a,b", so split the lists here
$SubscriptionIds = @($SubscriptionIds | ForEach-Object { "$_" -split ',' } | ForEach-Object Trim | Where-Object { $_ })
$VMNames = @($VMNames | ForEach-Object { "$_" -split ',' } | ForEach-Object Trim | Where-Object { $_ })

# ----- Cross-platform module bootstrap -----
# Make the script "just work" on any fresh Mac/Linux/Windows machine with PowerShell 7+
# by installing required Az modules to the current user scope on demand.
$requiredModules = @('Az.Accounts', 'Az.Compute', 'Az.Monitor')

if (-not $SkipModuleCheck) {
    Write-Host "Checking required PowerShell modules..." -ForegroundColor Yellow

    # Ensure PSGallery is trusted so Install-Module doesn't prompt interactively
    try {
        $gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        if ($gallery -and $gallery.InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Verbose "Could not adjust PSGallery policy: $($_.Exception.Message)"
    }

    foreach ($module in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-Host "  Installing $module (CurrentUser scope) — this can take a few minutes on first run..." -ForegroundColor Yellow
            try {
                Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            } catch {
                Write-Error "Failed to install $module. Run PowerShell once and execute: Install-Module $module -Scope CurrentUser`n$($_.Exception.Message)"
                exit 1
            }
        }
        try {
            Import-Module $module -ErrorAction Stop
        } catch {
            # Usually an older Az version already loaded in this session, or installed side by side
            Write-Error ("Failed to load $($module): $($_.Exception.Message)`n" +
                "Close every PowerShell window, then in a new pwsh run: Update-Module Az.Accounts, Az.Compute, Az.Monitor -Scope CurrentUser, and run the script again.")
            exit 1
        }
        Write-Host "  $module ready." -ForegroundColor Green
    }
}

# Ensures output directory exists
if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# ----- Transcript log (so customers can send us a single file when something goes wrong) -----
$logTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$transcriptPath = Join-Path -Path $OutputPath -ChildPath "VM_Assessment_$logTimestamp.log"
try {
    Start-Transcript -Path $transcriptPath -Force -ErrorAction Stop | Out-Null
    Write-Host "Logging to: $transcriptPath" -ForegroundColor DarkGray
} catch {
    Write-Verbose "Transcript could not be started: $($_.Exception.Message)"
}

# Output files share the log's timestamp. Rows go to the .partial.csv files as each batch
# finishes; the sorted final files replace them at the end of a complete run.
$metricsCsvPath     = Join-Path -Path $OutputPath -ChildPath "VM_Metrics_$logTimestamp.csv"
$availCsvPath       = Join-Path -Path $OutputPath -ChildPath "VM_Availability_$logTimestamp.csv"
$metricsPartialPath = Join-Path -Path $OutputPath -ChildPath "VM_Metrics_$logTimestamp.partial.csv"
$availPartialPath   = Join-Path -Path $OutputPath -ChildPath "VM_Availability_$logTimestamp.partial.csv"

# Initialising arrays to store results
$metricsResults = New-Object System.Collections.Generic.List[object]
$availabilityResults = New-Object System.Collections.Generic.List[object]

# Setting date range for metrics
$endTime = Get-Date
$startTime = $endTime.AddDays(-$DaysBack)

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "VM Metrics Collection Script (CSV) v2.5" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Date Range: $($startTime.ToString('yyyy-MM-dd')) to $($endTime.ToString('yyyy-MM-dd'))" -ForegroundColor Yellow
Write-Host "Days Back: $DaysBack days" -ForegroundColor Yellow
if ($TenantId) {
    Write-Host "Tenant ID: $TenantId" -ForegroundColor Yellow
} else {
    Write-Host "Tenant ID: $((Get-AzContext).Tenant.Id) (current context)" -ForegroundColor Yellow
}

if ($SubscriptionIds) {
    Write-Host "Subscription filter: $($SubscriptionIds -join ', ')" -ForegroundColor Yellow
}

if ($VMNames) {
    Write-Host "VM name filter: $($VMNames -join ', ')" -ForegroundColor Yellow
}

Write-Host ""

# ----- Param & Aggregation Types -----
function Convert-BytesToGiB {
    param([double]$Bytes)
    return [math]::Round($Bytes / 1GB, 2)
}

# 5-minute series for one VM straight from the Azure Monitor REST API, called with an access token
# so it also runs in the parallel runspaces, where Az PowerShell's shared sign-in can hang.
# $Metrics maps each metric name to the aggregations it needs; there is one request per aggregation,
# holding only the metrics that need it, which keeps responses small. Windows are fetched in
# 30-day chunks because the API returns at most 31 days per query.
# Returns @{ Data = name -> aggregation -> @{ timestamp = value }; Gaps = name -> chunk numbers;
# ChunkCount }. Only a metric the VM doesn't publish is dropped (and the request retried without
# it). Throttling, server errors and timeouts are retried; when retries run out, that chunk stays
# empty for those metrics and is recorded in Gaps, and later chunks are still fetched. A 401 returns
# @{ Unauthorized = $true } so the caller can retry the VM with a fresh token, unless -FinalAttempt,
# when it is recorded as a gap like any other failure.
function Get-MetricData {
    param(
        [string]$ResourceId,
        [hashtable]$Metrics,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [string]$Token,
        [string]$ResourceManagerUrl,
        [switch]$FinalAttempt
    )

    # Azure Monitor builds the 5-minute buckets from the query start, so start on a 5-minute boundary:
    # peaks then match the portal and don't depend on when the script was run
    $StartTime = $StartTime.ToUniversalTime()
    $StartTime = $StartTime.AddTicks(-($StartTime.Ticks % [timespan]::FromMinutes(5).Ticks))
    $EndTime = $EndTime.ToUniversalTime()

    $data = @{}
    $gaps = @{}
    $chunkCount = 0
    $names = [System.Collections.Generic.List[string]]::new([string[]]@($Metrics.Keys))
    $invariant = [cultureinfo]::InvariantCulture
    # Seconds this VM may spend waiting between retries. Once spent, or once a request has failed
    # all its attempts, the VM's remaining requests get a single attempt, so a throttled or failing
    # Azure Monitor can't hold one VM for hours
    $waitBudget = 600
    $addGap = {
        param([string[]]$GapNames)
        foreach ($gapName in $GapNames) {
            if (-not $gaps.ContainsKey($gapName)) { $gaps[$gapName] = [System.Collections.Generic.HashSet[int]]::new() }
            [void]$gaps[$gapName].Add($chunkCount)
        }
    }

    $chunkStart = $StartTime
    while ($chunkStart -lt $EndTime) {
        # The last chunk runs to the end time when that fits the 31-day limit, so no sliver is left over
        $chunkEnd = if (($EndTime - $chunkStart).TotalDays -le 31) { $EndTime } else { $chunkStart.AddDays(30) }
        $chunkCount++
        # Invariant culture: some locales write the time separator as '.', which the API rejects
        $timespan = "$($chunkStart.ToString('yyyy-MM-ddTHH:mm:ssZ', $invariant))/$($chunkEnd.ToString('yyyy-MM-ddTHH:mm:ssZ', $invariant))"

        foreach ($aggregation in 'Maximum', 'Average', 'Minimum', 'Total') {
            $queue = [System.Collections.Generic.Queue[object]]::new()
            $queue.Enqueue(@($names | Where-Object { $Metrics[$_] -contains $aggregation }))
            while ($queue.Count -gt 0) {
                $batch = @($queue.Dequeue() | Where-Object { $names.Contains($_) })
                if ($batch.Count -eq 0) { continue }
                $path = "$ResourceId/providers/Microsoft.Insights/metrics?api-version=2023-10-01" +
                    "&metricnames=$(($batch | ForEach-Object { [uri]::EscapeDataString($_) }) -join ',')" +
                    "&timespan=$timespan&interval=PT5M&aggregation=$($aggregation.ToLower())"

                # Up to 6 attempts on throttling, server errors, timeouts and unreadable replies, waiting as
                # long as Retry-After asks (at most 5 minutes) while the VM's wait budget lasts
                $response = $null
                $parsed = $null
                for ($attempt = 1; $attempt -le 6; $attempt++) {
                    $wait = [math]::Pow(2, $attempt)
                    try {
                        $web = Invoke-WebRequest -Uri "$($ResourceManagerUrl.TrimEnd('/'))$path" -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec 120 -SkipHttpErrorCheck -ErrorAction Stop
                        $response = [pscustomobject]@{ StatusCode = [int]$web.StatusCode; Content = "$($web.Content)" }
                        $retryAfter = 0
                        if ($web.Headers -and $web.Headers.ContainsKey('Retry-After') -and [int]::TryParse("$($web.Headers['Retry-After'])", [ref]$retryAfter) -and $retryAfter -gt 0) {
                            $wait = $retryAfter
                        }
                        # A cut-off 200 body is a failed attempt, not a reason to lose the VM
                        if ($response.StatusCode -eq 200) { $parsed = $response.Content | ConvertFrom-Json -ErrorAction Stop }
                    } catch { $response = $null }
                    if ($response -and $response.StatusCode -ne 429 -and $response.StatusCode -lt 500) { break }
                    if ($attempt -lt 6 -and $waitBudget -gt 0) {
                        Write-Verbose "Metrics request throttled or failed for '$($batch -join ', ')' (attempt $attempt)."
                        $sleep = [math]::Min([math]::Min(300, $wait), $waitBudget)
                        $waitBudget -= $sleep
                        Start-Sleep -Seconds $sleep
                    } else { break }
                }

                if (-not $response -or $response.StatusCode -eq 429 -or $response.StatusCode -ge 500) {
                    $waitBudget = 0
                    & $addGap $batch
                    Write-Verbose "Metrics request still failing after $attempt attempt(s) for '$($batch -join ', ')'; chunk $chunkCount left empty."
                    continue
                }

                if ($response.StatusCode -eq 401) {
                    if (-not $FinalAttempt) { return @{ Unauthorized = $true } }
                    & $addGap $batch
                    Write-Verbose "Metrics request unauthorized for '$($batch -join ', ')'; chunk $chunkCount left empty."
                    continue
                }

                if ($response.StatusCode -eq 200) {
                    foreach ($metric in @($parsed.value)) {
                        $name = $metric.name.value
                        if (-not $data.ContainsKey($name)) { $data[$name] = @{} }
                        if (-not $data[$name].ContainsKey($aggregation)) { $data[$name][$aggregation] = @{} }
                        $series = $data[$name][$aggregation]
                        foreach ($point in @($metric.timeseries | ForEach-Object { $_.data })) {
                            $value = $point.$aggregation
                            if ($null -ne $value) { $series[$point.timeStamp] = [double]$value }
                        }
                    }
                    continue
                }

                $body = try { $response.Content | ConvertFrom-Json } catch { $null }
                $message = "$($body.message ?? $body.error.message ?? $response.Content)"
                $missing = @($batch | Where-Object { $message -match [regex]::Escape("metric: $_,") })
                if ($missing.Count -gt 0) {
                    foreach ($name in $missing) { [void]$names.Remove($name); [void]$gaps.Remove($name); Write-Verbose "Metric '$name' not available for this VM." }
                    $queue.Enqueue($batch)
                } elseif ($message -match 'exceeded maximum limit' -and $batch.Count -gt 1) {
                    $half = [math]::Ceiling($batch.Count / 2)
                    $queue.Enqueue($batch[0..($half - 1)])
                    $queue.Enqueue($batch[$half..($batch.Count - 1)])
                } elseif ($batch.Count -gt 1) {
                    # Find which metric the request rejects by asking for each one alone
                    foreach ($name in $batch) { $queue.Enqueue(@($name)) }
                } else {
                    # Any other rejection of one metric on its own: keep the metric for later chunks
                    & $addGap $batch
                    Write-Verbose "Metric '$($batch[0])' request failed ($($response.StatusCode)): $message"
                }
            }
        }
        $chunkStart = $chunkEnd
    }
    return @{ Data = $data; Gaps = $gaps; ChunkCount = $chunkCount; MetricCount = $names.Count }
}

# Returns a hashtable of metric name -> @{ timestamp = value } for one aggregation, read from Get-MetricData
function Get-MetricSeries {
    param(
        [hashtable]$Data,
        [string[]]$MetricNames,
        [string]$Aggregation = "Maximum"
    )
    $result = @{}
    foreach ($name in $MetricNames) {
        if ($Data.ContainsKey($name)) { $result[$name] = $Data[$name][$Aggregation] ?? @{} }
    }
    return $result
}

# Summary statistics over one or more series. With several series the values are summed
# per timestamp first (e.g. read + write), so peaks are measured at the same moment.
function Get-SeriesStat {
    param(
        [hashtable[]]$Series,
        [ValidateSet('Max', 'Min', 'Average', 'P95')]
        [string]$Stat
    )

    $combined = @{}
    foreach ($s in $Series) {
        if (-not $s) { continue }
        foreach ($key in $s.Keys) { $combined[$key] = ($combined[$key] ?? 0) + $s[$key] }
    }
    if ($combined.Count -eq 0) { return $null }

    $values = [double[]]@($combined.Values)
    switch ($Stat) {
        'Max'     { return ($values | Measure-Object -Maximum).Maximum }
        'Min'     { return ($values | Measure-Object -Minimum).Minimum }
        'Average' { return ($values | Measure-Object -Average).Average }
        'P95'     {
            $sorted = $values | Sort-Object
            $index = [math]::Ceiling(0.95 * $sorted.Count) - 1
            return $sorted[[math]::Max(0, $index)]
        }
    }
}

# Clamp to a range and round. The Cloud Performance Lab upload rejects a row whose
# percentages fall outside 0-100, and bursting disks can report more than 100%.
function Limit-Value {
    param($Value, [double]$Min = 0, [double]$Max = [double]::MaxValue, [int]$Digits = 2)
    if ($null -eq $Value) { return $null }
    return [math]::Round([math]::Min($Max, [math]::Max($Min, [double]$Value)), $Digits)
}

# Every item of an ARM list call, following nextLink. Invoke-AzRestMethod ships in Az.Accounts,
# so network resources can be read without requiring Az.Network. Returns nothing on failure.
function Get-ArmList {
    param([string]$Path)
    $items = @()
    try {
        $response = Invoke-AzRestMethod -Path $Path -Method GET -ErrorAction Stop
        while ($response) {
            if ($response.StatusCode -ne 200) { Write-Verbose "GET $Path returned $($response.StatusCode)"; break }
            $page = $response.Content | ConvertFrom-Json
            $items += @($page.value)
            $response = if ($page.nextLink) { Invoke-AzRestMethod -Uri $page.nextLink -Method GET -ErrorAction Stop } else { $null }
        }
    } catch {
        Write-Verbose "GET $Path failed: $($_.Exception.Message)"
    }
    return $items
}

# Per-location SKU capabilities (temp disk size), cached per subscription + location.
$skuCache = @{}
function Get-SkuCapability {
    param([string]$SubscriptionId, [string]$Location, [string]$VMSize, [string]$Capability)
    $cacheKey = "$SubscriptionId/$Location"
    if (-not $skuCache.ContainsKey($cacheKey)) {
        $skuCache[$cacheKey] = @{}
        try {
            Get-AzComputeResourceSku -Location $Location -ErrorAction Stop |
                Where-Object ResourceType -eq 'virtualMachines' |
                ForEach-Object { $skuCache[$cacheKey][$_.Name] = $_ }
        } catch {
            Write-Verbose "Could not read VM SKUs for '$Location': $($_.Exception.Message)"
        }
    }
    $sku = $skuCache[$cacheKey][$VMSize]
    if (-not $sku) { return $null }
    return ($sku.Capabilities | Where-Object Name -eq $Capability | Select-Object -First 1).Value
}

# Availability % from VmAvailabilityMetric: each 5-minute average is the fraction of that interval
# the VM was available. $null when the metric isn't published, so the caller falls back to the Activity Log.
function Get-VMAvailability {
    param(
        [hashtable]$Data,
        [datetime]$StartTime,
        [datetime]$EndTime
    )
    if (-not $Data.ContainsKey('VmAvailabilityMetric')) { return $null }
    $series = $Data['VmAvailabilityMetric']['Average']
    $totalMinutes = ($EndTime - $StartTime).TotalMinutes
    # No data points at all: the VM was off the entire period
    if ($series.Count -eq 0 -or $totalMinutes -le 0) { return 0.00 }
    $availableMinutes = ($series.Values | Measure-Object -Sum).Sum * 5
    return [math]::Round([math]::Min(100, $availableMinutes / $totalMinutes * 100), 2)
}

# Fetches one VM's metrics and reduces them to the handful of values a CSV row needs, so the
# raw 5-minute series (up to ~100 MB per VM over 90 days) are freed as soon as the VM is done.
# Values are unrounded; the row builder clamps and rounds them. MetricGaps reads
# "<metric>:<failed chunks>/<chunks>;..." and is empty when every request succeeded.
function Get-VMMetricSummary {
    param(
        [string]$ResourceId,
        [hashtable]$Metrics,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [string]$Token,
        [string]$ResourceManagerUrl,
        [string[]]$PctMetricNames,
        [string[]]$TempMetricNames,
        [switch]$FinalAttempt
    )
    $fetched = Get-MetricData -ResourceId $ResourceId -Metrics $Metrics -StartTime $StartTime -EndTime $EndTime -Token $Token -ResourceManagerUrl $ResourceManagerUrl -FinalAttempt:$FinalAttempt
    if ($fetched.Unauthorized) { return @{ Unauthorized = $true } }
    $data = $fetched.Data

    $cpuMax = Get-MetricSeries -Data $data -MetricNames @("Percentage CPU") -Aggregation "Maximum"
    $cpuAvg = Get-MetricSeries -Data $data -MetricNames @("Percentage CPU") -Aggregation "Average"
    $memMin = Get-MetricSeries -Data $data -MetricNames @("Available Memory Bytes") -Aggregation "Minimum"
    $memAvg = Get-MetricSeries -Data $data -MetricNames @("Available Memory Bytes") -Aggregation "Average"
    $net = Get-MetricSeries -Data $data -MetricNames @("Network In Total", "Network Out Total") -Aggregation "Total"
    $diskOps = Get-MetricSeries -Data $data -MetricNames @("Disk Read Operations/Sec", "Disk Write Operations/Sec") -Aggregation "Average"
    $diskBytes = Get-MetricSeries -Data $data -MetricNames @("Disk Read Bytes", "Disk Write Bytes") -Aggregation "Total"
    $pct = Get-MetricSeries -Data $data -MetricNames $PctMetricNames -Aggregation "Maximum"
    $temp = Get-MetricSeries -Data $data -MetricNames $TempMetricNames -Aggregation "Average"

    $pctMax = @{}
    foreach ($name in $PctMetricNames) { $pctMax[$name] = Get-SeriesStat -Series $pct[$name] -Stat Max }

    # One entry when every metric the VM publishes failed the same way, e.g. "All metrics:3/3"
    $gapCounts = @($fetched.Gaps.Values | ForEach-Object { $_.Count } | Sort-Object -Unique)
    $metricGaps = if ($fetched.Gaps.Count -gt 0 -and $fetched.Gaps.Count -eq $fetched.MetricCount -and $gapCounts.Count -eq 1) {
        "All metrics:$($gapCounts[0])/$($fetched.ChunkCount)"
    } else {
        (@($fetched.Gaps.Keys | Sort-Object | ForEach-Object { "$($_):$($fetched.Gaps[$_].Count)/$($fetched.ChunkCount)" }) -join ';')
    }

    return @{
        MaxCPU            = Get-SeriesStat -Series $cpuMax["Percentage CPU"] -Stat Max
        AvgCPU            = Get-SeriesStat -Series $cpuAvg["Percentage CPU"] -Stat Average
        P95CPU            = Get-SeriesStat -Series $cpuAvg["Percentage CPU"] -Stat P95
        # Days actually covered by data; lower than CollectionPeriodDays for new or stopped VMs
        MetricDays        = if ($cpuAvg["Percentage CPU"]) { [math]::Round($cpuAvg["Percentage CPU"].Count * 5 / 1440, 1) } else { $null }
        MinAvailableBytes = Get-SeriesStat -Series $memMin["Available Memory Bytes"] -Stat Min
        AvgAvailableBytes = Get-SeriesStat -Series $memAvg["Available Memory Bytes"] -Stat Average
        # In and out are summed per interval so both peaks come from the same moment
        NetPeakBytes      = Get-SeriesStat -Series @($net["Network In Total"], $net["Network Out Total"]) -Stat Max
        NetOutPeakBytes   = Get-SeriesStat -Series $net["Network Out Total"] -Stat Max
        IopsPeak          = Get-SeriesStat -Series @($diskOps["Disk Read Operations/Sec"], $diskOps["Disk Write Operations/Sec"]) -Stat Max
        BytesPeak         = Get-SeriesStat -Series @($diskBytes["Disk Read Bytes"], $diskBytes["Disk Write Bytes"]) -Stat Max
        PctMax            = $pctMax
        TempIopsPeak      = Get-SeriesStat -Series @($temp["Temp Disk Read Operations/Sec"], $temp["Temp Disk Write Operations/Sec"]) -Stat Max
        TempBytesPeak     = Get-SeriesStat -Series @($temp["Temp Disk Read Bytes/sec"], $temp["Temp Disk Write Bytes/sec"]) -Stat Max
        # A failed chunk would count as downtime, so leave availability to the Activity Log estimate then
        Availability      = if ($fetched.Gaps.ContainsKey('VmAvailabilityMetric')) { $null } else { Get-VMAvailability -Data $data -StartTime $StartTime -EndTime $EndTime }
        MetricGaps        = $metricGaps
    }
}

function Get-VMUptimeFromActivityLog {
    param(
        [string]$ResourceId,
        [string]$VMName,
        [string]$ResourceGroup,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [string]$CurrentPowerState
    )
    try {
        $activities = Get-AzActivityLog `
            -ResourceId $ResourceId `
            -StartTime $StartTime `
            -MaxRecord 1000 `
            -WarningAction SilentlyContinue `
            -ErrorAction Stop | Where-Object {
                $_.OperationName.Value -like "*Microsoft.Compute/virtualMachines/*" -and
                ($_.Status.Value -eq "Succeeded" -or $_.Status.Value -eq "Started")
            }

        $isDeallocated = $CurrentPowerState -like "*deallocated*" -or $CurrentPowerState -like "*stopped*"
        $startEvents = $activities | Where-Object { $_.OperationName.Value -like "*start*" -and $_.OperationName.Value -notlike "*deallocate*" }
        $stopEvents  = $activities | Where-Object { $_.OperationName.Value -like "*deallocate*" -or $_.OperationName.Value -like "*powerOff*" }
        $totalMinutes = ($EndTime - $StartTime).TotalMinutes

        if ($isDeallocated -and $startEvents.Count -eq 0) { return 0.00 }
        if ($isDeallocated -and $startEvents.Count -gt 0) {
            $stateChanges = $startEvents.Count + $stopEvents.Count
            if ($stateChanges -gt 0) {
                $est = [math]::Round(($startEvents.Count / $stateChanges) * 100, 2)
                return [math]::Min($est, 90.00)
            }
        }
        if (-not $isDeallocated) {
            if ($stopEvents.Count -eq 0) { return 100.00 }
            $estDown = $stopEvents.Count * 5
            $uptime  = [math]::Round((($totalMinutes - $estDown) / $totalMinutes) * 100, 2)
            return [math]::Max($uptime, 50.00)
        }
        return $null
    } catch {
        Write-Verbose "Failed to calculate uptime from activity log: $($_.Exception.Message)"
        return $null
    }
}

# Appends rows to a .partial.csv with a '.' decimal separator. A failed write only warns:
# the rows are still in memory for the final file.
function Add-PartialRows {
    param([object[]]$Rows, [string]$Path)
    if (@($Rows).Count -eq 0) { return }
    $culture = [cultureinfo]::CurrentCulture
    [cultureinfo]::CurrentCulture = [cultureinfo]::InvariantCulture
    try {
        $Rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8 -Append -ErrorAction Stop
    } catch {
        Write-Warning "Could not save rows to '$Path': $($_.Exception.Message)"
    } finally {
        [cultureinfo]::CurrentCulture = $culture
    }
}

# ----- Gaining Auth & Context -----
$connectArgs = @{}
if ($TenantId) { $connectArgs['TenantId'] = $TenantId }
if ($UseDeviceAuthentication) { $connectArgs['UseDeviceAuthentication'] = $true }

function Connect-AzureSafely {
    param([hashtable]$ConnectArgs)
    # Az.Accounts 3+ prompts for a subscription after sign-in; the script walks every subscription itself.
    # Process scope leaves the user's saved Az config untouched. Older Az.Accounts has no such setting.
    try { Update-AzConfig -LoginExperienceV2 Off -Scope Process -ErrorAction Stop | Out-Null } catch {}
    try {
        Connect-AzAccount @ConnectArgs -ErrorAction Stop | Out-Null
    } catch {
        $hint = if ($ConnectArgs.ContainsKey('UseDeviceAuthentication')) { '' } else { "`nIf you don't have a browser available, re-run with -UseDeviceAuthentication." }
        Write-Error "Azure sign-in failed: $($_.Exception.Message)$hint"
        if ($transcriptPath) { try { Stop-Transcript | Out-Null } catch {} }
        exit 1
    }
}

try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context) { throw "Not connected" }
    # A saved sign-in can outlive its token (e.g. after MFA expiry); sign in again rather than find no subscriptions
    if (-not ($TenantId -and $context.Tenant.Id -ne $TenantId)) {
        $null = Get-AzAccessToken -TenantId $context.Tenant.Id -ErrorAction Stop -WarningAction SilentlyContinue
    }

    if ($TenantId -and $context.Tenant.Id -ne $TenantId) {
        Write-Host "Current context tenant: $($context.Tenant.Id). Switching to: $TenantId" -ForegroundColor Yellow
        Connect-AzureSafely -ConnectArgs $connectArgs
        $context = Get-AzContext
    } elseif ($TenantId) {
        Write-Host "Already in the requested tenant: $TenantId" -ForegroundColor Green
    } else {
        Write-Host "Already connected (Tenant: $($context.Tenant.Id))" -ForegroundColor Green
    }
    Write-Host "Connected as: $($context.Account.Id)" -ForegroundColor Green
} catch {
    Write-Host "Connecting to Azure..." -ForegroundColor Yellow
    if ($UseDeviceAuthentication) {
        Write-Host "Using device authentication. Open the URL shown below and enter the code." -ForegroundColor Yellow
    }
    Connect-AzureSafely -ConnectArgs $connectArgs
    $context = Get-AzContext
}

if (-not $context -or -not $context.Account) {
    Write-Error "No Azure context available after sign-in. Aborting."
    if ($transcriptPath) { try { Stop-Transcript | Out-Null } catch {} }
    exit 1
}

# ----- Metrics to collect, with the aggregations each needs -----
$pctMetricNames = @(
    "OS Disk Bandwidth Consumed Percentage",
    "OS Disk IOPS Consumed Percentage",
    "Data Disk Bandwidth Consumed Percentage",
    "Data Disk IOPS Consumed Percentage",
    "VM Uncached Bandwidth Consumed Percentage",
    "VM Uncached IOPS Consumed Percentage"
)
$tempMetricNames = @("Temp Disk Read Operations/Sec", "Temp Disk Write Operations/Sec", "Temp Disk Read Bytes/sec", "Temp Disk Write Bytes/sec")
$metricRequests = @{
    "Percentage CPU"            = @("Maximum", "Average")
    "Available Memory Bytes"    = @("Minimum", "Average")
    "Network In Total"          = @("Total")
    "Network Out Total"         = @("Total")
    "Disk Read Operations/Sec"  = @("Average")
    "Disk Write Operations/Sec" = @("Average")
    "Disk Read Bytes"           = @("Total")
    "Disk Write Bytes"          = @("Total")
}
foreach ($name in $pctMetricNames) { $metricRequests[$name] = @("Maximum") }
foreach ($name in $tempMetricNames) { $metricRequests[$name] = @("Average") }
if ($IncludeAvailability) { $metricRequests["VmAvailabilityMetric"] = @("Average") }

# Metrics are fetched for this many VMs at a time with one access token. Small batches keep each
# token well inside its lifetime and keep the .partial.csv files current.
$batchSize = 25

# The functions the parallel runspaces need, as one script they dot-source
$workerFunctions = (@('Get-MetricData', 'Get-MetricSeries', 'Get-SeriesStat', 'Get-VMAvailability', 'Get-VMMetricSummary') |
    ForEach-Object { "function $_ {`n$((Get-Item "function:$_").ScriptBlock)`n}" }) -join "`n"

# Metric summaries for a set of VMs, keyed by lower-case VM id, $ThrottleLimit VMs at a time (the calls
# are I/O-bound). Gets a fresh access token for each call; the runspaces call Resource Manager with it
# directly. A VM whose fetch failed outright has no entry.
function Get-MetricSummaries {
    param([object[]]$VMs, [switch]$FinalAttempt)

    $tokenInfo = Get-AzAccessToken -WarningAction SilentlyContinue -ErrorAction Stop
    $token = if ($tokenInfo.Token -is [securestring]) { ConvertFrom-SecureString $tokenInfo.Token -AsPlainText } else { $tokenInfo.Token }
    $armUrl = (Get-AzContext).Environment.ResourceManagerUrl
    $summaries = [System.Collections.Concurrent.ConcurrentDictionary[string, hashtable]]::new()

    if ($ThrottleLimit -gt 1) {
        $verbose = $VerbosePreference
        $VMs | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            . ([scriptblock]::Create($using:workerFunctions))
            $VerbosePreference = $using:verbose
            $summary = Get-VMMetricSummary -ResourceId $_.Id -Metrics $using:metricRequests -StartTime $using:startTime -EndTime $using:endTime `
                -Token $using:token -ResourceManagerUrl $using:armUrl -PctMetricNames $using:pctMetricNames -TempMetricNames $using:tempMetricNames `
                -FinalAttempt:$using:FinalAttempt
            ($using:summaries)[$_.Id.ToLower()] = $summary
        }
    } else {
        foreach ($vm in $VMs) {
            $summaries[$vm.Id.ToLower()] = Get-VMMetricSummary -ResourceId $vm.Id -Metrics $metricRequests -StartTime $startTime -EndTime $endTime `
                -Token $token -ResourceManagerUrl $armUrl -PctMetricNames $pctMetricNames -TempMetricNames $tempMetricNames -FinalAttempt:$FinalAttempt
        }
    }
    return $summaries
}

# ----- Subscriptions -----
Write-Host "`nRetrieving subscriptions..." -ForegroundColor Yellow
try {
    if ($TenantId) {
        Write-Host "Filtering subscriptions for Tenant ID: $TenantId" -ForegroundColor Cyan
        $subscriptions = Get-AzSubscription -TenantId $TenantId -ErrorAction Stop | Where-Object { $_.State -eq "Enabled" }
    } else {
        $currentTenantId = (Get-AzContext).Tenant.Id
        Write-Host "Using subscriptions from current tenant: $currentTenantId" -ForegroundColor Cyan
        $subscriptions = Get-AzSubscription -TenantId $currentTenantId -ErrorAction Stop | Where-Object { $_.State -eq "Enabled" }
    }
} catch {
    Write-Error "Failed to list subscriptions: $($_.Exception.Message)"
    if ($transcriptPath) { try { Stop-Transcript | Out-Null } catch {} }
    exit 1
}

if ($SubscriptionIds) {
    $notFound = @($SubscriptionIds | Where-Object { $_ -notin @($subscriptions | ForEach-Object Id) })
    if ($notFound.Count -gt 0) {
        Write-Warning "Not among the enabled subscriptions this account can read: $($notFound -join ', ')"
    }
    $subscriptions = @($subscriptions | Where-Object { $_.Id -in $SubscriptionIds })
    if ($subscriptions.Count -eq 0) {
        Write-Error "None of the subscriptions given with -SubscriptionIds are enabled subscriptions this account can read."
        if ($transcriptPath) { try { Stop-Transcript | Out-Null } catch {} }
        exit 1
    }
}

if (-not $subscriptions -or @($subscriptions).Count -eq 0) {
    Write-Warning "No enabled subscriptions found for the current account/tenant. Verify you signed in with an account that has at least Reader access."
    if ($transcriptPath) { try { Stop-Transcript | Out-Null } catch {} }
    exit 0
}

Write-Host "Found $(@($subscriptions).Count) enabled subscription(s)." -ForegroundColor Green
Write-Host ""

# Count VMs for progress (per-subscription tolerant of access errors)
$totalVMs = 0
$processedVMs = 0

foreach ($subscription in $subscriptions) {
    try {
        Set-AzContext -SubscriptionId $subscription.Id -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Cannot set context to subscription '$($subscription.Name)': $($_.Exception.Message). Skipping for count."
        continue
    }

    try {
        $vms = Get-AzVM -Status -ErrorAction Stop
    } catch {
        Write-Verbose "Get-AzVM -Status failed in '$($subscription.Name)' ($($_.Exception.Message)). Falling back to Get-AzVM without status."
        try { $vms = Get-AzVM -ErrorAction Stop } catch { $vms = @() }
    }

    if ($VMNames) {
        $vms = @($vms | Where-Object { $VMNames -contains $_.Name })
    }

    $totalVMs += @($vms).Count
}

if ($totalVMs -eq 0) {
    if ($VMNames) {
        Write-Warning "None of the requested VMs were found in any in-scope subscription."
        Write-Host "VMs requested: $($VMNames -join ', ')" -ForegroundColor Yellow
    } else {
        Write-Warning "No VMs found across the in-scope subscriptions."
    }
    if ($transcriptPath) { try { Stop-Transcript | Out-Null } catch {} }
    exit 0
}

if ($DaysBack -gt 30 -and $totalVMs -gt 200) {
    Write-Host "$totalVMs VMs over $DaysBack days can take a few hours. To finish sooner, re-run with -DaysBack 30, or split the run with -SubscriptionIds." -ForegroundColor Yellow
}
Write-Host "Rows are saved as they are collected to $metricsPartialPath; if the run stops, send that file with the log." -ForegroundColor DarkGray
Write-Host ""

# ----- Data Collection Stage -----
$skippedScaleSets = 0
$vmsWithGaps = 0
$stoppedEarly = $false
$failedSubscriptions = [System.Collections.Generic.List[string]]::new()
foreach ($subscription in $subscriptions) {
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "Processing Subscription: $($subscription.Name)" -ForegroundColor Cyan
    Write-Host "Subscription ID: $($subscription.Id)" -ForegroundColor Gray
    Write-Host "=====================================" -ForegroundColor Cyan

    try {
        Set-AzContext -SubscriptionId $subscription.Id -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null

        try {
            $vms = Get-AzVM -Status -ErrorAction Stop
        } catch {
            Write-Warning "Get-AzVM -Status failed: $($_.Exception.Message). Retrying without -Status (PowerState will be unknown)."
            $vms = Get-AzVM -ErrorAction Stop
        }

        if ($VMNames) {
            $vms = @($vms | Where-Object { $VMNames -contains $_.Name })
        }

        if (-not $vms -or @($vms).Count -eq 0) {
            Write-Host "No VMs found in this subscription." -ForegroundColor Yellow
            Write-Host ""
            continue
        }

        Write-Host "Found $(@($vms).Count) VM(s)." -ForegroundColor Green

        # Managed disks once per subscription: SKU, provisioned performance, Hyper-V generation
        $disksById = @{}
        try {
            Get-AzDisk -ErrorAction Stop | ForEach-Object { $disksById[$_.Id.ToLower()] = $_ }
        } catch {
            Write-Verbose "Get-AzDisk failed in '$($subscription.Name)': $($_.Exception.Message)"
        }

        # NICs and public IPs once per subscription, for the IP allocation columns
        $nicsById = @{}
        $publicIpsById = @{}
        foreach ($nic in (Get-ArmList "/subscriptions/$($subscription.Id)/providers/Microsoft.Network/networkInterfaces?api-version=2024-05-01")) { $nicsById[$nic.id.ToLower()] = $nic }
        foreach ($pip in (Get-ArmList "/subscriptions/$($subscription.Id)/providers/Microsoft.Network/publicIPAddresses?api-version=2024-05-01")) { $publicIpsById[$pip.id.ToLower()] = $pip }

        # SQL Server registrations (SQL IaaS extension), keyed by VM id
        $sqlByVmId = @{}
        foreach ($sql in (Get-ArmList "/subscriptions/$($subscription.Id)/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines?api-version=2022-02-01")) {
            if ($sql.properties.virtualMachineResourceId) { $sqlByVmId[$sql.properties.virtualMachineResourceId.ToLower()] = $sql }
        }

        # Resource groups owned by a service (AKS, Databricks, managed apps): a deny assignment can block changes
        $managedRgs = @{}
        foreach ($rg in (Get-ArmList "/subscriptions/$($subscription.Id)/resourcegroups?api-version=2021-04-01")) {
            if ($rg.managedBy) { $managedRgs[$rg.name.ToLower()] = $rg.managedBy }
        }

        # Assignments of the built-in "Allowed virtual machine size SKUs" policy, including ones inherited
        # from management groups. Custom policies that restrict sizes are not detected.
        $sizePolicies = @(Get-ArmList "/subscriptions/$($subscription.Id)/providers/Microsoft.Authorization/policyAssignments?api-version=2022-06-01" |
            Where-Object { $_.properties.policyDefinitionId -like '*/policyDefinitions/cccc23c7-8427-4f53-ad12-b6a63eb452b3' })
        foreach ($policy in $sizePolicies) {
            Write-Warning "Allowed VM sizes policy '$($policy.properties.displayName ?? $policy.name)' at $($policy.properties.scope): $(@($policy.properties.parameters.listOfAllowedSKUs.value) -join ', ')"
        }

        # Uniform scale set instances (including AKS node pools) are not returned by Get-AzVM
        try {
            $uniformScaleSets = @(Get-AzVmss -ErrorAction Stop | Where-Object { $_.OrchestrationMode -ne 'Flexible' })
            if ($uniformScaleSets.Count -gt 0) {
                Write-Warning "$($uniformScaleSets.Count) Uniform VM scale set(s) in this subscription are not included (e.g. AKS node pools): $(($uniformScaleSets | Select-Object -ExpandProperty Name) -join ', ')"
                $skippedScaleSets += $uniformScaleSets.Count
            }
        } catch {
            Write-Verbose "Get-AzVmss failed in '$($subscription.Name)': $($_.Exception.Message)"
        }
        Write-Host ""

        $vmList = @($vms)
        for ($offset = 0; $offset -lt $vmList.Count; $offset += $batchSize) {
            $batch = @($vmList[$offset..([math]::Min($offset + $batchSize - 1, $vmList.Count - 1))])
            Write-Host "Fetching metrics for VMs $($offset + 1)-$($offset + $batch.Count) of $($vmList.Count), $ThrottleLimit at a time..." -ForegroundColor Cyan
            try {
                $summaries = Get-MetricSummaries -VMs $batch
            } catch {
                # No access token: the sign-in has lapsed, and every later batch would fail the same way
                Write-Error "Could not get an access token for the metrics requests: $($_.Exception.Message). Stopping the run early; sign in again (Connect-AzAccount) and re-run."
                $stoppedEarly = $true
                break
            }

            # A token can expire or be revoked mid-batch: retry those VMs once with a fresh one
            $unauthorized = @($batch | Where-Object { $summaries[$_.Id.ToLower()].Unauthorized })
            if ($unauthorized.Count -gt 0) {
                Write-Warning "$($unauthorized.Count) VM(s) got an expired or rejected access token; retrying them once with a fresh one."
                foreach ($vm in $unauthorized) { [void]$summaries.TryRemove($vm.Id.ToLower(), [ref]$null) }
                try {
                    $retried = Get-MetricSummaries -VMs $unauthorized -FinalAttempt
                    foreach ($key in $retried.Keys) { $summaries[$key] = $retried[$key] }
                } catch {
                    Write-Warning "Could not get a fresh access token: $($_.Exception.Message). Those VMs are written without metrics."
                }
            }

            $batchMetrics = New-Object System.Collections.Generic.List[object]
            $batchAvailability = New-Object System.Collections.Generic.List[object]

            foreach ($vm in $batch) {
                $processedVMs++
                # Autoscaling (e.g. AKS node pools) can add VMs after the initial count
                if ($processedVMs -gt $totalVMs) { $totalVMs = $processedVMs }
                $percentComplete = if ($totalVMs -gt 0) { [math]::Round(($processedVMs / $totalVMs) * 100, 2) } else { 100 }

                $powerState = if ($vm.PowerState) { $vm.PowerState } else { "Unknown" }
                Write-Host "[$processedVMs/$totalVMs - $percentComplete%] VM: $($vm.Name)" -ForegroundColor Yellow
                Write-Host "  RG: $($vm.ResourceGroupName) | Location: $($vm.Location) | Power: $powerState" -ForegroundColor Gray

                $vmResourceId = $vm.Id

                # Build metrics row / column headers. The first 20 columns are what the Cloud
                # Performance Lab upload reads; keep their names and order. Move-readiness
                # columns are appended after them and are ignored by the upload.
                $vmMetrics = [PSCustomObject]@{
                    SubscriptionName        = $subscription.Name
                    SubscriptionId          = $subscription.Id
                    ResourceGroup           = $vm.ResourceGroupName
                    VMName                  = $vm.Name
                    Location                = $vm.Location
                    VMSize                  = $vm.HardwareProfile.VmSize
                    PowerState              = $powerState
                    OSType                  = $vm.StorageProfile.OsDisk.OsType

                    MaxCPUPercent           = $null
                    AvgCPUPercent           = $null
                    TotalCPUCores           = $null

                    MaxMemoryUsedGiB        = $null
                    AvgMemoryUsedGiB        = $null
                    TotalAllocatedMemoryGiB = $null

                    MaxNetworkBandwidthMbps = $null

                    MaxDiskBandwidthPercent = $null

                    MaxIOPSPercent          = $null

                    CollectionPeriodDays    = $DaysBack
                    CollectionStartDate     = $startTime.ToString("yyyy-MM-dd")
                    CollectionEndDate       = $endTime.ToString("yyyy-MM-dd")

                    # Utilisation detail
                    P95CPUPercent             = $null
                    MetricDays                = $null
                    MaxNetworkOutMbps         = $null
                    MaxDiskIOPS               = $null
                    MaxDiskMBps               = $null
                    MaxVMUncachedIOPSPercent  = $null
                    MaxVMUncachedMBpsPercent  = $null
                    MaxDataDiskIOPSPercent    = $null
                    MaxDataDiskMBpsPercent    = $null

                    # Move readiness
                    Zone                      = ($vm.Zones -join ';')
                    AvailabilitySet           = if ($vm.AvailabilitySetReference.Id) { ($vm.AvailabilitySetReference.Id -split '/')[-1] } else { '' }
                    ScaleSet                  = if ($vm.VirtualMachineScaleSet.Id) { ($vm.VirtualMachineScaleSet.Id -split '/')[-1] } else { '' }
                    # Set on VM-type node pools (aks-managed-poolName) and Node Auto Provisioning nodes (karpenter.sh_nodepool)
                    AksNodePool               = if ($vm.Tags) { @('aks-managed-poolName', 'karpenter.sh_nodepool') | ForEach-Object { $vm.Tags[$_] } | Where-Object { $_ } | Select-Object -First 1 } else { '' }
                    HyperVGeneration          = $null
                    SecurityType              = $vm.SecurityProfile.SecurityType
                    DiskControllerType        = $vm.StorageProfile.DiskControllerType
                    TempDiskGiB               = $null
                    DataDiskCount             = @($vm.StorageProfile.DataDisks).Count
                    DiskSkus                  = $null
                    ProvisionedDiskIOPS       = $null
                    ProvisionedDiskMBps       = $null
                    NicCount                  = @($vm.NetworkProfile.NetworkInterfaces).Count
                    LicenseType               = $vm.LicenseType
                    ImagePublisher            = $vm.StorageProfile.ImageReference.Publisher
                    ImageOffer                = $vm.StorageProfile.ImageReference.Offer
                    ImageSku                  = $vm.StorageProfile.ImageReference.Sku
                    MaxTempDiskIOPS           = $null
                    MaxTempDiskMBps           = $null
                    # An ephemeral OS disk is wiped when the size changes; placement is CacheDisk, ResourceDisk or NvmeDisk
                    EphemeralOsDisk           = if ($vm.StorageProfile.OsDisk.DiffDiskSettings.Option -eq 'Local') { $vm.StorageProfile.OsDisk.DiffDiskSettings.Placement ?? 'CacheDisk' } else { '' }
                    PrivateIPAllocation       = $null
                    PublicIPAllocation        = $null

                    # Placement and platform constraints on which sizes the VM can move to
                    ProximityPlacementGroup   = if ($vm.ProximityPlacementGroup.Id) { ($vm.ProximityPlacementGroup.Id -split '/')[-1] } else { '' }
                    DedicatedHost             = if ($vm.Host.Id) { (($vm.Host.Id -split '/')[-3, -1]) -join '/' } elseif ($vm.HostGroup.Id) { ($vm.HostGroup.Id -split '/')[-1] } else { '' }
                    Priority                  = if ($vm.Priority -and $vm.Priority -ne 'Regular') { $vm.Priority } else { '' }
                    CapacityReservationGroup  = if ($vm.CapacityReservation.CapacityReservationGroup.Id) { ($vm.CapacityReservation.CapacityReservationGroup.Id -split '/')[-1] } else { '' }
                    MarketplacePlan           = if ($vm.Plan.Publisher) { "$($vm.Plan.Publisher)/$($vm.Plan.Product)" } else { '' }
                    IPForwarding              = $null
                    AcceleratedNetworking     = $null
                    LoadBalanced              = $null
                    SharedDisk                = $null
                    SqlServer                 = ''
                    SqlAvailabilityGroup      = ''
                    ManagedResourceGroup      = if ($managedRgs[$vm.ResourceGroupName.ToLower()]) { ($managedRgs[$vm.ResourceGroupName.ToLower()] -split '/providers/')[-1] } else { '' }
                    AllowedSizesPolicy        = ''

                    # Metrics whose data is incomplete because requests kept failing: "<metric>:<failed chunks>/<chunks>"
                    MetricGaps                = ''
                }

                # Allowed VM sizes policy in scope: assigned at a management group, or at this VM's subscription,
                # resource group or the VM itself, and the VM not excluded
                $vmIdLower = $vmResourceId.ToLower()
                $inScope = $sizePolicies | Where-Object {
                    $scope = $_.properties.scope.ToLower()
                    ($scope -like '/providers/microsoft.management/managementgroups/*' -or $vmIdLower -eq $scope -or $vmIdLower.StartsWith("$scope/")) -and
                    -not (@($_.properties.notScopes) | Where-Object { $_ -and ($vmIdLower -eq $_.ToLower() -or $vmIdLower.StartsWith("$($_.ToLower())/")) })
                }
                if ($inScope) { $vmMetrics.AllowedSizesPolicy = 'Yes' }

                # SQL Server edition (licensed per core) and Always On availability group, if registered
                $sqlVm = $sqlByVmId[$vmIdLower]
                if ($sqlVm) {
                    $vmMetrics.SqlServer = $sqlVm.properties.sqlImageSku ?? 'Registered'
                    if ($sqlVm.properties.sqlVirtualMachineGroupResourceId) { $vmMetrics.SqlAvailabilityGroup = ($sqlVm.properties.sqlVirtualMachineGroupResourceId -split '/')[-1] }
                }

                $summary = $summaries[$vmIdLower]
                if (-not $summary -or $summary.Unauthorized) {
                    $summary = @{ MetricGaps = 'All metrics:fetch failed' }
                    Write-Warning "  Metrics could not be fetched for this VM (see errors above)."
                }
                $pctMax = $summary.PctMax ?? @{}
                $vmMetrics.MetricGaps = $summary.MetricGaps
                if ($summary.MetricGaps) {
                    $vmsWithGaps++
                    Write-Warning "  Incomplete metrics after retries: $($summary.MetricGaps)"
                }

                # CPU: peak from the per-interval maximum, average and P95 from the 5-minute averages
                $maxCPU = Limit-Value $summary.MaxCPU -Max 100
                $avgCPU = Limit-Value $summary.AvgCPU -Max 100
                $p95CPU = Limit-Value $summary.P95CPU -Max 100
                $vmMetrics.MaxCPUPercent = $maxCPU
                # The upload rejects a row whose average is above its maximum, so never let rounding do that
                $vmMetrics.AvgCPUPercent = if ($null -ne $avgCPU -and $null -ne $maxCPU) { [math]::Min($avgCPU, $maxCPU) } else { $avgCPU }
                $vmMetrics.P95CPUPercent = if ($null -ne $p95CPU -and $null -ne $maxCPU) { [math]::Min($p95CPU, $maxCPU) } else { $p95CPU }
                $vmMetrics.MetricDays = $summary.MetricDays

                # Memory - Calculate USED memory (Total - Available)
                # vCPUs and memory from the cached SKU list (vCPUsAvailable for constrained-core sizes);
                # Get-AzVMSize, one call per VM, only when the SKU list has no entry for the size
                $skuArgs = @{ SubscriptionId = $subscription.Id; Location = $vm.Location; VMSize = $vm.HardwareProfile.VmSize }
                $skuCores = (Get-SkuCapability @skuArgs -Capability 'vCPUsAvailable') ?? (Get-SkuCapability @skuArgs -Capability 'vCPUs')
                $skuMemoryGB = Get-SkuCapability @skuArgs -Capability 'MemoryGB'
                $vmSizeInfo = if ($skuCores -and $skuMemoryGB) {
                    [pscustomobject]@{ NumberOfCores = [int]$skuCores; MemoryInMB = [double]::Parse($skuMemoryGB, [cultureinfo]::InvariantCulture) * 1024 }
                } else {
                    Get-AzVMSize -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name |
                        Where-Object { $_.Name -eq $vm.HardwareProfile.VmSize }
                }

                # Total CPU Cores
                if ($null -ne $vmSizeInfo) {
                    $vmMetrics.TotalCPUCores = $vmSizeInfo.NumberOfCores
                }

                # Total Memory GiB
                $TotalAllocatedMemoryGiB = $null
                if ($null -ne $vmSizeInfo) {
                    $TotalAllocatedMemoryGiB = $vmSizeInfo.MemoryInMB / 1024
                    $vmMetrics.TotalAllocatedMemoryGiB = [math]::Round($TotalAllocatedMemoryGiB, 2)
                }

                # Max used = total - minimum available; average used = total - average available.
                # Clamped to 0..allocated, which the upload requires.
                $minAvailableBytes = $summary.MinAvailableBytes
                $avgAvailableBytes = $summary.AvgAvailableBytes

                if ($null -ne $TotalAllocatedMemoryGiB) {
                    $allocated = $vmMetrics.TotalAllocatedMemoryGiB
                    if ($null -ne $minAvailableBytes) {
                        $vmMetrics.MaxMemoryUsedGiB = Limit-Value ($TotalAllocatedMemoryGiB - $minAvailableBytes / 1GB) -Max $allocated -Digits 3
                    }
                    if ($null -ne $avgAvailableBytes) {
                        $avgUsed = Limit-Value ($TotalAllocatedMemoryGiB - $avgAvailableBytes / 1GB) -Max $allocated -Digits 3
                        $vmMetrics.AvgMemoryUsedGiB = if ($null -ne $vmMetrics.MaxMemoryUsedGiB) { [math]::Min($avgUsed, $vmMetrics.MaxMemoryUsedGiB) } else { $avgUsed }
                    }
                }

                # Network: bytes per 5-minute interval -> Mbps averaged over that interval
                $bytesToMbps = 8 / (300 * 1000000)
                if ($null -ne $summary.NetPeakBytes) { $vmMetrics.MaxNetworkBandwidthMbps = Limit-Value ($summary.NetPeakBytes * $bytesToMbps) }
                # Azure network limits per VM size apply to outbound traffic
                if ($null -ne $summary.NetOutPeakBytes) { $vmMetrics.MaxNetworkOutMbps = Limit-Value ($summary.NetOutPeakBytes * $bytesToMbps) }

                # Disk throughput across all disks (host metrics, no agent needed), as absolute
                # values that can be compared with any target size's limits
                if ($null -ne $summary.IopsPeak) { $vmMetrics.MaxDiskIOPS = Limit-Value $summary.IopsPeak -Digits 0 }
                if ($null -ne $summary.BytesPeak) { $vmMetrics.MaxDiskMBps = Limit-Value ($summary.BytesPeak / 300 / 1MB) }

                # Consumed percentages: OS disk (upload columns), data disks, and the VM-level caps
                $vmMetrics.MaxDiskBandwidthPercent  = Limit-Value $pctMax["OS Disk Bandwidth Consumed Percentage"] -Max 100
                $vmMetrics.MaxIOPSPercent           = Limit-Value $pctMax["OS Disk IOPS Consumed Percentage"] -Max 100
                $vmMetrics.MaxDataDiskMBpsPercent   = Limit-Value $pctMax["Data Disk Bandwidth Consumed Percentage"] -Max 100
                $vmMetrics.MaxDataDiskIOPSPercent   = Limit-Value $pctMax["Data Disk IOPS Consumed Percentage"] -Max 100
                $vmMetrics.MaxVMUncachedMBpsPercent = Limit-Value $pctMax["VM Uncached Bandwidth Consumed Percentage"] -Max 100
                $vmMetrics.MaxVMUncachedIOPSPercent = Limit-Value $pctMax["VM Uncached IOPS Consumed Percentage"] -Max 100

                # Disks: SKUs, provisioned performance, Hyper-V generation (from the OS disk)
                $diskRefs = @($vm.StorageProfile.OsDisk) + @($vm.StorageProfile.DataDisks)
                $disks = @($diskRefs | ForEach-Object { if ($_.ManagedDisk.Id) { $disksById[$_.ManagedDisk.Id.ToLower()] } } | Where-Object { $_ })
                if ($disks.Count -gt 0) {
                    $vmMetrics.DiskSkus = (@($disks | ForEach-Object { $_.Sku.Name }) | Sort-Object -Unique) -join ';'
                    $vmMetrics.ProvisionedDiskIOPS = ($disks | Measure-Object -Property DiskIOPSReadWrite -Sum -ErrorAction SilentlyContinue).Sum
                    $vmMetrics.ProvisionedDiskMBps = ($disks | Measure-Object -Property DiskMBpsReadWrite -Sum -ErrorAction SilentlyContinue).Sum
                    # A disk attached to several VMs is typically a failover cluster's shared storage
                    $vmMetrics.SharedDisk = [bool]($disks | Where-Object { $_.MaxShares -gt 1 })
                }
                $osDiskId = $vm.StorageProfile.OsDisk.ManagedDisk.Id
                if ($osDiskId -and $disksById[$osDiskId.ToLower()]) {
                    $vmMetrics.HyperVGeneration = $disksById[$osDiskId.ToLower()].HyperVGeneration
                }

                # Temp disk on the current size; Azure cannot resize directly between sizes with and without one
                $tempDiskMB = Get-SkuCapability -SubscriptionId $subscription.Id -Location $vm.Location -VMSize $vm.HardwareProfile.VmSize -Capability 'MaxResourceVolumeMB'
                if ($null -ne $tempDiskMB) { $vmMetrics.TempDiskGiB = [math]::Round([double]$tempDiskMB / 1024, 0) }

                # Temp disk use (e.g. Windows pagefile on D:), so a move to a size without one can be judged
                if ($vmMetrics.TempDiskGiB -ne 0) {
                    if ($null -ne $summary.TempIopsPeak) { $vmMetrics.MaxTempDiskIOPS = Limit-Value $summary.TempIopsPeak -Digits 0 }
                    if ($null -ne $summary.TempBytesPeak) { $vmMetrics.MaxTempDiskMBps = Limit-Value ($summary.TempBytesPeak / 1MB) }
                }

                # IP allocation: a dynamic public IP is released when the VM is stopped, a dynamic
                # private IP when the NIC is replaced (e.g. a rebuild onto a new size)
                $nics = @($vm.NetworkProfile.NetworkInterfaces | ForEach-Object { if ($_.Id) { $nicsById[$_.Id.ToLower()] } } | Where-Object { $_ })
                $ipConfigs = @($nics | ForEach-Object { $_.properties.ipConfigurations })
                if ($nics.Count -gt 0) {
                    # IP forwarding marks a network virtual appliance; a backend pool, a VM that changes with its peers
                    $vmMetrics.IPForwarding = [bool]($nics | Where-Object { $_.properties.enableIPForwarding })
                    $vmMetrics.AcceleratedNetworking = [bool]($nics | Where-Object { $_.properties.enableAcceleratedNetworking })
                    $vmMetrics.LoadBalanced = [bool]($ipConfigs | Where-Object { $_.properties.loadBalancerBackendAddressPools -or $_.properties.applicationGatewayBackendAddressPools })
                }
                if ($ipConfigs.Count -gt 0) {
                    $vmMetrics.PrivateIPAllocation = (@($ipConfigs | ForEach-Object { $_.properties.privateIPAllocationMethod }) | Sort-Object -Unique) -join ';'
                    $vmMetrics.PublicIPAllocation = (@($ipConfigs | ForEach-Object { if ($_.properties.publicIPAddress.id) { $publicIpsById[$_.properties.publicIPAddress.id.ToLower()].properties.publicIPAllocationMethod } } | Where-Object { $_ }) | Sort-Object -Unique) -join ';'
                }

                $batchMetrics.Add($vmMetrics) | Out-Null

                # Availability (optional)
                if ($IncludeAvailability) {
                    $availabilityData = [PSCustomObject]@{
                        SubscriptionName          = $subscription.Name
                        SubscriptionId            = $subscription.Id
                        ResourceGroup             = $vm.ResourceGroupName
                        VMName                    = $vm.Name
                        Location                  = $vm.Location
                        PowerState                = $powerState
                        AvailabilityPercent       = $null
                        UptimeCalculationMethod   = "None"
                        CollectionPeriodDays      = $DaysBack
                        CollectionStartDate       = $startTime.ToString("yyyy-MM-dd")
                        CollectionEndDate         = $endTime.ToString("yyyy-MM-dd")
                    }

                    if ($null -ne $summary.Availability) {
                        $availabilityData.AvailabilityPercent = $summary.Availability
                        $availabilityData.UptimeCalculationMethod = "VM Availability Metric (Preview)"
                    } else {
                        $uptimeFromLogs = Get-VMUptimeFromActivityLog -ResourceId $vmResourceId -VMName $vm.Name -ResourceGroup $vm.ResourceGroupName -StartTime $startTime -EndTime $endTime -CurrentPowerState $powerState
                        if ($null -ne $uptimeFromLogs) {
                            $availabilityData.AvailabilityPercent = $uptimeFromLogs
                            $availabilityData.UptimeCalculationMethod = "Estimated from Activity Logs"
                        }
                    }

                    $batchAvailability.Add($availabilityData) | Out-Null
                }
            }

            # Keep the rows for the final sorted files, and save them now in case the run stops
            $metricsResults.AddRange($batchMetrics)
            $availabilityResults.AddRange($batchAvailability)
            Add-PartialRows -Rows $batchMetrics -Path $metricsPartialPath
            Add-PartialRows -Rows $batchAvailability -Path $availPartialPath
        }
    } catch {
        Write-Error "Error processing subscription '$($subscription.Name)': $($_.Exception.Message)"
        Write-Host ""
        $failedSubscriptions.Add($subscription.Name)
        continue
    }
    if ($stoppedEarly) { break }
}

# ----- Export to CSVs -----
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Exporting Results to CSV" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan

# Write numbers with a '.' decimal separator whatever the machine's locale. On e.g. Nordic
# or German locales they would otherwise come out as "97,34", which the upload rejects.
$originalCulture = [cultureinfo]::CurrentCulture
[cultureinfo]::CurrentCulture = [cultureinfo]::InvariantCulture

try {
    if ($metricsResults.Count -gt 0) {
        $metricsResults `
            | Sort-Object SubscriptionName, ResourceGroup, VMName `
            | Export-Csv -Path $metricsCsvPath -NoTypeInformation -Encoding UTF8
        Write-Host "Metrics CSV: $metricsCsvPath  (rows: $($metricsResults.Count))" -ForegroundColor Green

        # Cloud Performance Lab accepts files up to 5 MB and 10,000 rows
        $csvSizeMB = (Get-Item -LiteralPath $metricsCsvPath).Length / 1MB
        if ($csvSizeMB -gt 5 -or $metricsResults.Count -gt 10000) {
            Write-Warning ("The metrics CSV is {0:N1} MB with {1} rows, above the Cloud Performance Lab upload limit (5 MB, 10,000 rows). Re-run per group of subscriptions with -SubscriptionIds, or split the file, before uploading." -f $csvSizeMB, $metricsResults.Count)
        }
    } else {
        Write-Warning "No metrics data to export."
    }

    if ($IncludeAvailability -and $availabilityResults.Count -gt 0) {
        $availabilityResults `
            | Sort-Object SubscriptionName, ResourceGroup, VMName `
            | Export-Csv -Path $availCsvPath -NoTypeInformation -Encoding UTF8
        Write-Host "Availability CSV: $availCsvPath  (rows: $($availabilityResults.Count))" -ForegroundColor Green
    } elseif ($IncludeAvailability) {
        Write-Warning "Availability collection was requested but no rows were generated."
    }

    $incomplete = $stoppedEarly -or $failedSubscriptions.Count -gt 0
    if (-not $incomplete) {
        # The final files hold every row now, so the partial ones are no longer needed
        Remove-Item -LiteralPath $metricsPartialPath, $availPartialPath -ErrorAction SilentlyContinue
    }

    Write-Host ""
    if ($incomplete) {
        Write-Host "=====================================" -ForegroundColor Red
        Write-Host "Export INCOMPLETE" -ForegroundColor Red
        Write-Host "=====================================" -ForegroundColor Red
        if ($stoppedEarly) { Write-Warning "The run stopped early because the sign-in lapsed; VMs after the last saved batch are missing." }
        if ($failedSubscriptions.Count -gt 0) { Write-Warning "Subscription(s) that failed part-way or entirely: $($failedSubscriptions -join ', ') (see errors above)." }
        Write-Warning "Re-run for the missing subscriptions with -SubscriptionIds. The .partial.csv files are kept; send them with the log."
    } else {
        Write-Host "=====================================" -ForegroundColor Green
        Write-Host "Export Complete!" -ForegroundColor Green
        Write-Host "=====================================" -ForegroundColor Green
    }
    Write-Host "Total VMs processed: $processedVMs of $totalVMs" -ForegroundColor Yellow
    if ($skippedScaleSets -gt 0) {
        Write-Host "Uniform scale sets not included: $skippedScaleSets (see warnings above)" -ForegroundColor Yellow
    }
    if ($vmsWithGaps -gt 0) {
        Write-Warning "$vmsWithGaps VM(s) have incomplete metrics after retries (see the MetricGaps column); their values come from the data that did arrive. Re-running later, or with -ThrottleLimit 1, usually fills the gaps."
    }
    Write-Host ""

} catch {
    Write-Error "Failed to export CSV: $($_.Exception.Message)"
} finally {
    [cultureinfo]::CurrentCulture = $originalCulture
}

Write-Host "Script execution completed." -ForegroundColor Cyan

if ($transcriptPath) {
    try { Stop-Transcript | Out-Null } catch {}
}
