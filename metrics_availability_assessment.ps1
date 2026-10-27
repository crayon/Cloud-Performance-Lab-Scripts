<#
.SYNOPSIS
    Collects VM performance metrics and availability data across all Azure subscriptions

.DESCRIPTION
    Outputs to flat **CSV files**
    - VM_Metrics_yyyyMMdd_HHmmss.csv
    - VM_Availability_yyyyMMdd_HHmmss.csv  (only if -IncludeAvailability)

.PARAMETER DaysBack
    Number of days to look back for metrics (default: 30)
    Note: Azure retains metrics data for a maximum of 30 days for look back analysis.

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
    pwsh -File ./metrics_availability_assessment.ps1 -DaysBack 30 -IncludeAvailability

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
    [int]$DaysBack = 30,

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

# ----- Friendly look-back warning (Azure metrics retention is 30 days) -----
if ($DaysBack -gt 30) {
    Write-Warning "Azure VM metrics are retained for 30 days. Values for days older than 30 will be empty."
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
Write-Host "VM Metrics Collection Script (CSV)" -ForegroundColor Cyan
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

# Returns a hashtable of metric name -> @{ timestamp = value } for the 5-minute series.
# Several metrics share one call; if that call fails for a non-transient reason (e.g. one
# metric is not published for this VM), each metric is retried on its own so one missing
# metric never blanks the others.
function Get-MetricSeries {
    param(
        [string]$ResourceId,
        [string[]]$MetricNames,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [string]$Aggregation = "Maximum"
    )

    $result = @{}
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $metrics = Get-AzMetric `
                -ResourceId $ResourceId `
                -MetricName $MetricNames `
                -StartTime $StartTime `
                -EndTime $EndTime `
                -TimeGrain 00:05:00 `
                -Aggregation $Aggregation `
                -WarningAction SilentlyContinue `
                -ErrorAction Stop

            foreach ($metric in @($metrics)) {
                $series = @{}
                foreach ($point in @($metric.Data)) {
                    $value = $point.$Aggregation
                    if ($null -ne $value) { $series[$point.TimeStamp] = [double]$value }
                }
                $result[$metric.Name.Value] = $series
            }
            return $result
        } catch {
            $msg = $_.Exception.Message
            # Retry on throttling / transient errors with exponential backoff
            if ($msg -match '429|throttle|TooManyRequests|timeout|temporar' -and $attempt -lt $maxAttempts) {
                $delay = [math]::Pow(2, $attempt)
                Write-Verbose "Throttled on '$($MetricNames -join ', ')' (attempt $attempt). Sleeping $delay s."
                Start-Sleep -Seconds $delay
                continue
            }
            if ($MetricNames.Count -gt 1) {
                foreach ($name in $MetricNames) {
                    $single = Get-MetricSeries -ResourceId $ResourceId -MetricNames @($name) -StartTime $StartTime -EndTime $EndTime -Aggregation $Aggregation
                    foreach ($key in $single.Keys) { $result[$key] = $single[$key] }
                }
                return $result
            }
            Write-Verbose "Metric '$($MetricNames -join ', ')' not available: $msg"
            return $result
        }
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

function Get-VMAvailability {
    param(
        [string]$ResourceId,
        [datetime]$StartTime,
        [datetime]$EndTime
    )
    try {
        $metric = Get-AzMetric -ResourceId $ResourceId `
            -MetricName "VmAvailabilityMetric" `
            -StartTime $StartTime `
            -EndTime $EndTime `
            -TimeGrain 01:00:00 `
            -WarningAction SilentlyContinue `
            -ErrorAction Stop

        # Calculate total hours in the period
        $totalHours = ($EndTime - $StartTime).TotalHours
        
        if ($metric.Data.Count -gt 0) {
            # Count how many hours the VM was available (had data points with value = 1)
            $availableHours = ($metric.Data | Where-Object { $_.Average -eq 1 }).Count
            
            # Calculate actual availability percentage
            if ($totalHours -gt 0) {
                return [math]::Round(($availableHours / $totalHours) * 100, 2)
            }
        }
        
        # If no data points at all, VM was off the entire period
        return 0.00
        
    } catch {
        Write-Verbose "Availability metric not available: $($_.Exception.Message)"
        return $null
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
            }

            # CPU: peak from the per-interval maximum, average and P95 from the 5-minute averages
            $cpuMax = Get-MetricSeries -ResourceId $vmResourceId -MetricNames @("Percentage CPU") -StartTime $startTime -EndTime $endTime -Aggregation "Maximum"
            $cpuAvg = Get-MetricSeries -ResourceId $vmResourceId -MetricNames @("Percentage CPU") -StartTime $startTime -EndTime $endTime -Aggregation "Average"

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
            $vmSizeInfo = Get-AzVMSize `
                -ResourceGroupName $vm.ResourceGroupName `
                -VMName $vm.Name |
                Where-Object { $_.Name -eq $vm.HardwareProfile.VmSize }

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
            $memMin = Get-MetricSeries -ResourceId $vmResourceId -MetricNames @("Available Memory Bytes") -StartTime $startTime -EndTime $endTime -Aggregation "Minimum"
            $memAvg = Get-MetricSeries -ResourceId $vmResourceId -MetricNames @("Available Memory Bytes") -StartTime $startTime -EndTime $endTime -Aggregation "Average"
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
            $net = Get-MetricSeries -ResourceId $vmResourceId -MetricNames @("Network In Total", "Network Out Total") -StartTime $startTime -EndTime $endTime -Aggregation "Total"
            $bytesToMbps = 8 / (300 * 1000000)
            $netPeakBytes = Get-SeriesStat -Series @($net["Network In Total"], $net["Network Out Total"]) -Stat Max
            $netOutPeakBytes = Get-SeriesStat -Series $net["Network Out Total"] -Stat Max
            if ($null -ne $netPeakBytes) { $vmMetrics.MaxNetworkBandwidthMbps = Limit-Value ($netPeakBytes * $bytesToMbps) }
            # Azure network limits per VM size apply to outbound traffic
            if ($null -ne $netOutPeakBytes) { $vmMetrics.MaxNetworkOutMbps = Limit-Value ($netOutPeakBytes * $bytesToMbps) }

            # Disk throughput across all disks (host metrics, no agent needed), as absolute
            # values that can be compared with any target size's limits
            $diskOps = Get-MetricSeries -ResourceId $vmResourceId -MetricNames @("Disk Read Operations/Sec", "Disk Write Operations/Sec") -StartTime $startTime -EndTime $endTime -Aggregation "Average"
            $diskBytes = Get-MetricSeries -ResourceId $vmResourceId -MetricNames @("Disk Read Bytes", "Disk Write Bytes") -StartTime $startTime -EndTime $endTime -Aggregation "Total"
            $iopsPeak = Get-SeriesStat -Series @($diskOps["Disk Read Operations/Sec"], $diskOps["Disk Write Operations/Sec"]) -Stat Max
            $bytesPeak = Get-SeriesStat -Series @($diskBytes["Disk Read Bytes"], $diskBytes["Disk Write Bytes"]) -Stat Max
            if ($null -ne $iopsPeak) { $vmMetrics.MaxDiskIOPS = Limit-Value $iopsPeak -Digits 0 }
            if ($null -ne $bytesPeak) { $vmMetrics.MaxDiskMBps = Limit-Value ($bytesPeak / 300 / 1MB) }

            # Consumed percentages: OS disk (upload columns), data disks, and the VM-level caps
            $pctNames = @(
                "OS Disk Bandwidth Consumed Percentage",
                "OS Disk IOPS Consumed Percentage",
                "Data Disk Bandwidth Consumed Percentage",
                "Data Disk IOPS Consumed Percentage",
                "VM Uncached Bandwidth Consumed Percentage",
                "VM Uncached IOPS Consumed Percentage"
            )
            $pct = Get-MetricSeries -ResourceId $vmResourceId -MetricNames $pctNames -StartTime $startTime -EndTime $endTime -Aggregation "Maximum"
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
            }
            $osDiskId = $vm.StorageProfile.OsDisk.ManagedDisk.Id
            if ($osDiskId -and $disksById[$osDiskId.ToLower()]) {
                $vmMetrics.HyperVGeneration = $disksById[$osDiskId.ToLower()].HyperVGeneration
            }

            # Temp disk on the current size; Azure cannot resize directly between sizes with and without one
            $tempDiskMB = Get-SkuCapability -SubscriptionId $subscription.Id -Location $vm.Location -VMSize $vm.HardwareProfile.VmSize -Capability 'MaxResourceVolumeMB'
            if ($null -ne $tempDiskMB) { $vmMetrics.TempDiskGiB = [math]::Round([double]$tempDiskMB / 1024, 0) }

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

                $availability = Get-VMAvailability -ResourceId $vmResourceId -StartTime $startTime -EndTime $endTime
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
