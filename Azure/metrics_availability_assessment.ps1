<#
.SYNOPSIS
    Collects VM performance metrics and availability data across all Azure subscriptions

.DESCRIPTION
    Outputs to flat **CSV files**
    - VM_Metrics_yyyyMMdd_HHmmss.csv
    - VM_Availability_yyyyMMdd_HHmmss.csv  (only if -IncludeAvailability)

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
    Date: October 2026
    Version: 2.4 (move-readiness columns, locale-safe CSV)
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
    [string[]]$VMNames,

    [Parameter(Mandatory = $false)]
    [switch]$UseDeviceAuthentication,

    [Parameter(Mandatory = $false)]
    [switch]$SkipModuleCheck
)

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
        Import-Module $module -ErrorAction Stop
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

# Initialising arrays to store results
$metricsResults = New-Object System.Collections.Generic.List[object]
$availabilityResults = New-Object System.Collections.Generic.List[object]

# Setting date range for metrics
$endTime = Get-Date
$startTime = $endTime.AddDays(-$DaysBack)

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "VM Metrics Collection Script (CSV) v2.4" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Date Range: $($startTime.ToString('yyyy-MM-dd')) to $($endTime.ToString('yyyy-MM-dd'))" -ForegroundColor Yellow
Write-Host "Days Back: $DaysBack days" -ForegroundColor Yellow
if ($TenantId) {
    Write-Host "Tenant ID: $TenantId" -ForegroundColor Yellow
} else {
    Write-Host "Tenant ID: $((Get-AzContext).Tenant.Id) (current context)" -ForegroundColor Yellow
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

# 5-minute series for one VM straight from the Azure Monitor REST API (Invoke-AzRestMethod is in
# Az.Accounts). $Metrics maps each metric name to the aggregations it needs; there is one request
# per aggregation, holding only the metrics that need it, which keeps responses small. Windows are
# fetched in 30-day chunks because the API returns at most 31 days per query.
# Returns name -> aggregation -> @{ timestamp = value }. A metric the VM doesn't publish is dropped
# and the request retried, so one missing metric never blanks the others; a batch over the API's
# 8 MB response limit is split in two. With -Token the requests go straight to Resource Manager
# with a timeout, without Az PowerShell, which is what the parallel runspaces use.
function Get-MetricData {
    param(
        [string]$ResourceId,
        [hashtable]$Metrics,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [string]$Token,
        [string]$ResourceManagerUrl
    )

    # Azure Monitor builds the 5-minute buckets from the query start, so start on a 5-minute boundary:
    # peaks then match the portal and don't depend on when the script was run
    $StartTime = $StartTime.ToUniversalTime()
    $StartTime = $StartTime.AddTicks(-($StartTime.Ticks % [timespan]::FromMinutes(5).Ticks))

    $result = @{}
    $names = [System.Collections.Generic.List[string]]::new([string[]]@($Metrics.Keys))
    $invariant = [cultureinfo]::InvariantCulture
    for ($chunkStart = $StartTime; $chunkStart -lt $EndTime; $chunkStart = $chunkStart.AddDays(30)) {
        $chunkEnd = if ($chunkStart.AddDays(30) -lt $EndTime) { $chunkStart.AddDays(30) } else { $EndTime }
        # Invariant culture: some locales write the time separator as '.', which the API rejects
        $timespan = "$($chunkStart.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $invariant))/$($chunkEnd.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $invariant))"

        foreach ($aggregation in 'Maximum', 'Average', 'Minimum', 'Total') {
            $queue = [System.Collections.Generic.Queue[object]]::new()
            $queue.Enqueue(@($names | Where-Object { $Metrics[$_] -contains $aggregation }))
            while ($queue.Count -gt 0) {
                $batch = @($queue.Dequeue() | Where-Object { $names.Contains($_) })
                if ($batch.Count -eq 0) { continue }
                $path = "$ResourceId/providers/Microsoft.Insights/metrics?api-version=2023-10-01" +
                    "&metricnames=$(($batch | ForEach-Object { [uri]::EscapeDataString($_) }) -join ',')" +
                    "&timespan=$timespan&interval=PT5M&aggregation=$($aggregation.ToLower())"

                # Retry on throttling and transient errors with exponential backoff
                $response = $null
                for ($attempt = 1; $attempt -le 4; $attempt++) {
                    try {
                        $response = if ($Token) {
                            $web = Invoke-WebRequest -Uri "$($ResourceManagerUrl.TrimEnd('/'))$path" -Headers @{ Authorization = "Bearer $Token" } -TimeoutSec 120 -SkipHttpErrorCheck -ErrorAction Stop
                            [pscustomobject]@{ StatusCode = [int]$web.StatusCode; Content = "$($web.Content)" }
                        } else {
                            Invoke-AzRestMethod -Path $path -Method GET -ErrorAction Stop
                        }
                    } catch { $response = $null }
                    if ($response -and $response.StatusCode -ne 429 -and $response.StatusCode -lt 500) { break }
                    if ($attempt -lt 4) {
                        Write-Verbose "Metrics request throttled or failed for '$($batch -join ', ')' (attempt $attempt)."
                        Start-Sleep -Seconds ([math]::Pow(2, $attempt))
                    }
                }
                if (-not $response) { Write-Verbose "Metrics request failed for '$($batch -join ', ')'."; continue }

                if ($response.StatusCode -eq 200) {
                    foreach ($metric in @(($response.Content | ConvertFrom-Json).value)) {
                        $name = $metric.name.value
                        if (-not $result.ContainsKey($name)) { $result[$name] = @{} }
                        if (-not $result[$name].ContainsKey($aggregation)) { $result[$name][$aggregation] = @{} }
                        $series = $result[$name][$aggregation]
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
                    foreach ($name in $missing) { [void]$names.Remove($name); Write-Verbose "Metric '$name' not available for this VM." }
                    $queue.Enqueue($batch)
                } elseif ($message -match 'exceeded maximum limit' -and $batch.Count -gt 1) {
                    $half = [math]::Ceiling($batch.Count / 2)
                    $queue.Enqueue($batch[0..($half - 1)])
                    $queue.Enqueue($batch[$half..($batch.Count - 1)])
                } elseif ($batch.Count -gt 1) {
                    foreach ($name in $batch) { $queue.Enqueue(@($name)) }
                } else {
                    [void]$names.Remove($batch[0])
                    Write-Verbose "Metric '$($batch[0])' not available: $message"
                }
            }
        }
    }
    return $result
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

if (-not $subscriptions -or $subscriptions.Count -eq 0) {
    Write-Warning "No enabled subscriptions found for the current account/tenant. Verify you signed in with an account that has at least Reader access."
    if ($transcriptPath) { try { Stop-Transcript | Out-Null } catch {} }
    exit 0
}

Write-Host "Found $($subscriptions.Count) enabled subscription(s)." -ForegroundColor Green
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

# ----- Data Collection Stage -----
$skippedScaleSets = 0
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

        # Metrics for every VM in the subscription, $ThrottleLimit VMs at a time (the calls are I/O-bound).
        # Az PowerShell's shared sign-in can hang when used from several threads, so the runspaces call
        # Resource Manager directly with an access token, refreshed every 100 VMs; the loop below reads the results.
        Write-Host "Fetching metrics for $(@($vms).Count) VM(s), $ThrottleLimit at a time..." -ForegroundColor Cyan
        $metricsByVm = [System.Collections.Concurrent.ConcurrentDictionary[string, hashtable]]::new()
        if ($ThrottleLimit -gt 1) {
            $fetchFunction = ${function:Get-MetricData}.ToString()
            $armUrl = (Get-AzContext).Environment.ResourceManagerUrl
            $verbose = $VerbosePreference
            $vmList = @($vms)
            for ($offset = 0; $offset -lt $vmList.Count; $offset += 100) {
                $tokenInfo = Get-AzAccessToken -WarningAction SilentlyContinue -ErrorAction Stop
                $token = if ($tokenInfo.Token -is [securestring]) { ConvertFrom-SecureString $tokenInfo.Token -AsPlainText } else { $tokenInfo.Token }
                $vmList[$offset..([math]::Min($offset + 99, $vmList.Count - 1))] | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
                    ${function:Get-MetricData} = [scriptblock]::Create($using:fetchFunction)
                    $VerbosePreference = $using:verbose
                    $data = Get-MetricData -ResourceId $_.Id -Metrics $using:metricRequests -StartTime $using:startTime -EndTime $using:endTime -Token $using:token -ResourceManagerUrl $using:armUrl
                    ($using:metricsByVm)[$_.Id.ToLower()] = $data
                }
            }
        } else {
            foreach ($vm in $vms) {
                $metricsByVm[$vm.Id.ToLower()] = Get-MetricData -ResourceId $vm.Id -Metrics $metricRequests -StartTime $startTime -EndTime $endTime
            }
        }

        foreach ($vm in $vms) {
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

            $metricData = $metricsByVm[$vmResourceId.ToLower()] ?? @{}

            # CPU: peak from the per-interval maximum, average and P95 from the 5-minute averages
            $cpuMax = Get-MetricSeries -Data $metricData -MetricNames @("Percentage CPU") -Aggregation "Maximum"
            $cpuAvg = Get-MetricSeries -Data $metricData -MetricNames @("Percentage CPU") -Aggregation "Average"

            $maxCPU = Limit-Value (Get-SeriesStat -Series $cpuMax["Percentage CPU"] -Stat Max) -Max 100
            $avgCPU = Limit-Value (Get-SeriesStat -Series $cpuAvg["Percentage CPU"] -Stat Average) -Max 100
            $p95CPU = Limit-Value (Get-SeriesStat -Series $cpuAvg["Percentage CPU"] -Stat P95) -Max 100
            $vmMetrics.MaxCPUPercent = $maxCPU
            # The upload rejects a row whose average is above its maximum, so never let rounding do that
            $vmMetrics.AvgCPUPercent = if ($null -ne $avgCPU -and $null -ne $maxCPU) { [math]::Min($avgCPU, $maxCPU) } else { $avgCPU }
            $vmMetrics.P95CPUPercent = if ($null -ne $p95CPU -and $null -ne $maxCPU) { [math]::Min($p95CPU, $maxCPU) } else { $p95CPU }
            if ($cpuAvg["Percentage CPU"]) {
                # Days actually covered by data; lower than CollectionPeriodDays for new or stopped VMs
                $vmMetrics.MetricDays = [math]::Round($cpuAvg["Percentage CPU"].Count * 5 / 1440, 1)
            }

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
            $memMin = Get-MetricSeries -Data $metricData -MetricNames @("Available Memory Bytes") -Aggregation "Minimum"
            $memAvg = Get-MetricSeries -Data $metricData -MetricNames @("Available Memory Bytes") -Aggregation "Average"
            $minAvailableBytes = Get-SeriesStat -Series $memMin["Available Memory Bytes"] -Stat Min
            $avgAvailableBytes = Get-SeriesStat -Series $memAvg["Available Memory Bytes"] -Stat Average

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

            # Network: bytes per 5-minute interval -> Mbps averaged over that interval.
            # In and out are summed per interval so both peaks come from the same moment.
            $net = Get-MetricSeries -Data $metricData -MetricNames @("Network In Total", "Network Out Total") -Aggregation "Total"
            $bytesToMbps = 8 / (300 * 1000000)
            $netPeakBytes = Get-SeriesStat -Series @($net["Network In Total"], $net["Network Out Total"]) -Stat Max
            $netOutPeakBytes = Get-SeriesStat -Series $net["Network Out Total"] -Stat Max
            if ($null -ne $netPeakBytes) { $vmMetrics.MaxNetworkBandwidthMbps = Limit-Value ($netPeakBytes * $bytesToMbps) }
            # Azure network limits per VM size apply to outbound traffic
            if ($null -ne $netOutPeakBytes) { $vmMetrics.MaxNetworkOutMbps = Limit-Value ($netOutPeakBytes * $bytesToMbps) }

            # Disk throughput across all disks (host metrics, no agent needed), as absolute
            # values that can be compared with any target size's limits
            $diskOps = Get-MetricSeries -Data $metricData -MetricNames @("Disk Read Operations/Sec", "Disk Write Operations/Sec") -Aggregation "Average"
            $diskBytes = Get-MetricSeries -Data $metricData -MetricNames @("Disk Read Bytes", "Disk Write Bytes") -Aggregation "Total"
            $iopsPeak = Get-SeriesStat -Series @($diskOps["Disk Read Operations/Sec"], $diskOps["Disk Write Operations/Sec"]) -Stat Max
            $bytesPeak = Get-SeriesStat -Series @($diskBytes["Disk Read Bytes"], $diskBytes["Disk Write Bytes"]) -Stat Max
            if ($null -ne $iopsPeak) { $vmMetrics.MaxDiskIOPS = Limit-Value $iopsPeak -Digits 0 }
            if ($null -ne $bytesPeak) { $vmMetrics.MaxDiskMBps = Limit-Value ($bytesPeak / 300 / 1MB) }

            # Consumed percentages: OS disk (upload columns), data disks, and the VM-level caps
            $pct = Get-MetricSeries -Data $metricData -MetricNames $pctMetricNames -Aggregation "Maximum"
            $vmMetrics.MaxDiskBandwidthPercent  = Limit-Value (Get-SeriesStat -Series $pct["OS Disk Bandwidth Consumed Percentage"] -Stat Max) -Max 100
            $vmMetrics.MaxIOPSPercent           = Limit-Value (Get-SeriesStat -Series $pct["OS Disk IOPS Consumed Percentage"] -Stat Max) -Max 100
            $vmMetrics.MaxDataDiskMBpsPercent   = Limit-Value (Get-SeriesStat -Series $pct["Data Disk Bandwidth Consumed Percentage"] -Stat Max) -Max 100
            $vmMetrics.MaxDataDiskIOPSPercent   = Limit-Value (Get-SeriesStat -Series $pct["Data Disk IOPS Consumed Percentage"] -Stat Max) -Max 100
            $vmMetrics.MaxVMUncachedMBpsPercent = Limit-Value (Get-SeriesStat -Series $pct["VM Uncached Bandwidth Consumed Percentage"] -Stat Max) -Max 100
            $vmMetrics.MaxVMUncachedIOPSPercent = Limit-Value (Get-SeriesStat -Series $pct["VM Uncached IOPS Consumed Percentage"] -Stat Max) -Max 100

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
                $temp = Get-MetricSeries -Data $metricData -MetricNames $tempMetricNames -Aggregation "Average"
                $tempIops = Get-SeriesStat -Series @($temp["Temp Disk Read Operations/Sec"], $temp["Temp Disk Write Operations/Sec"]) -Stat Max
                $tempBytes = Get-SeriesStat -Series @($temp["Temp Disk Read Bytes/sec"], $temp["Temp Disk Write Bytes/sec"]) -Stat Max
                if ($null -ne $tempIops) { $vmMetrics.MaxTempDiskIOPS = Limit-Value $tempIops -Digits 0 }
                if ($null -ne $tempBytes) { $vmMetrics.MaxTempDiskMBps = Limit-Value ($tempBytes / 1MB) }
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

            $metricsResults.Add($vmMetrics) | Out-Null

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

                $availability = Get-VMAvailability -Data $metricData -StartTime $startTime -EndTime $endTime
                if ($null -ne $availability) {
                    $availabilityData.AvailabilityPercent = $availability
                    $availabilityData.UptimeCalculationMethod = "VM Availability Metric (Preview)"
                } else {
                    $uptimeFromLogs = Get-VMUptimeFromActivityLog -ResourceId $vmResourceId -VMName $vm.Name -ResourceGroup $vm.ResourceGroupName -StartTime $startTime -EndTime $endTime -CurrentPowerState $powerState
                    if ($null -ne $uptimeFromLogs) {
                        $availabilityData.AvailabilityPercent = $uptimeFromLogs
                        $availabilityData.UptimeCalculationMethod = "Estimated from Activity Logs"
                    }
                }

                $availabilityResults.Add($availabilityData) | Out-Null
            }
        }
    } catch {
        Write-Error "Error processing subscription '$($subscription.Name)': $($_.Exception.Message)"
        Write-Host ""
        continue
    }
}

# ----- Export to CSVs -----
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Exporting Results to CSV" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$metricsCsvPath = Join-Path -Path $OutputPath -ChildPath "VM_Metrics_$timestamp.csv"
$availCsvPath   = Join-Path -Path $OutputPath -ChildPath "VM_Availability_$timestamp.csv"

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
            Write-Warning ("The metrics CSV is {0:N1} MB with {1} rows, above the Cloud Performance Lab upload limit (5 MB, 10,000 rows). Split it into smaller files, e.g. by subscription, before uploading." -f $csvSizeMB, $metricsResults.Count)
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

    Write-Host ""
    Write-Host "=====================================" -ForegroundColor Green
    Write-Host "Export Complete!" -ForegroundColor Green
    Write-Host "=====================================" -ForegroundColor Green
    Write-Host "Total VMs processed: $processedVMs" -ForegroundColor Yellow
    if ($skippedScaleSets -gt 0) {
        Write-Host "Uniform scale sets not included: $skippedScaleSets (see warnings above)" -ForegroundColor Yellow
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

<#
.NOTES
Performance: if the script is running too slowly, or hit API limits, 
you might have to increase -TimeGrain value. Current value set for 5min 00:05:00, which produces the most accurate results for Avg values. 
#>
