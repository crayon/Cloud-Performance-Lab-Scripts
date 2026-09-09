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
    Date: December 2025
    Version: 2.3 (cross-platform CSV, hardened)
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

function Get-MetricValue {
    param(
        [string]$ResourceId,
        [string]$MetricName,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [string]$Aggregation = "Maximum"
    )

    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $metric = Get-AzMetric `
                -ResourceId $ResourceId `
                -MetricName $MetricName `
                -StartTime $StartTime `
                -EndTime $EndTime `
                -TimeGrain 00:05:00 `
                -Aggregation $Aggregation `
                -WarningAction SilentlyContinue `
                -ErrorAction Stop

            if ($metric.Data.Count -gt 0) {
                switch ($Aggregation) {
                    "Maximum"       { $vals = $metric.Data | Where-Object Maximum -ne $null | Select-Object -ExpandProperty Maximum; if ($vals) { return ($vals | Measure-Object -Maximum).Maximum } }
                    "Minimum"       { $vals = $metric.Data | Where-Object Minimum -ne $null | Select-Object -ExpandProperty Minimum; if ($vals) { return ($vals | Measure-Object -Minimum).Minimum } }
                    "Average"       { $vals = $metric.Data | Where-Object Average -ne $null | Select-Object -ExpandProperty Average; if ($vals) { return ($vals | Measure-Object -Average).Average } }
                    "Total"         { $vals = $metric.Data | Where-Object Total   -ne $null | Select-Object -ExpandProperty Total;   if ($vals) { return ($vals | Measure-Object -Sum).Sum } }
                }
            }
            return $null
        } catch {
            $msg = $_.Exception.Message
            # Retry on throttling / transient errors with exponential backoff
            if ($msg -match '429|throttle|TooManyRequests|timeout|temporar' -and $attempt -lt $maxAttempts) {
                $delay = [math]::Pow(2, $attempt)
                Write-Verbose "Throttled on '$MetricName' (attempt $attempt). Sleeping $delay s."
                Start-Sleep -Seconds $delay
                continue
            }
            Write-Verbose "Metric '$MetricName' not available: $msg"
            return $null
        }
    }
    return $null
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
    try {
        Connect-AzAccount @ConnectArgs -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "Azure sign-in failed: $($_.Exception.Message)`nIf you don't have a browser available, re-run with -UseDeviceAuthentication."
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
        Write-Host ""

        foreach ($vm in $vms) {
            $processedVMs++
            $percentComplete = if ($totalVMs -gt 0) { [math]::Round(($processedVMs / $totalVMs) * 100, 2) } else { 100 }

            $powerState = if ($vm.PowerState) { $vm.PowerState } else { "Unknown" }
            Write-Host "[$processedVMs/$totalVMs - $percentComplete%] VM: $($vm.Name)" -ForegroundColor Yellow
            Write-Host "  RG: $($vm.ResourceGroupName) | Location: $($vm.Location) | Power: $powerState" -ForegroundColor Gray

            $vmResourceId = $vm.Id

            # Build metrics row / column headers
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
            }

            # CPU - max
            $maxCPU = Get-MetricValue `
                -ResourceId $vmResourceId `
                -MetricName "Percentage CPU" `
                -StartTime $startTime `
                -EndTime $endTime `
                -Aggregation "Maximum"

            if ($null -ne $maxCPU) { 
                $vmMetrics.MaxCPUPercent = [math]::Round($maxCPU, 2) }
            
            # CPU - avg
            $avgCPU = Get-MetricValue `
                -ResourceId $vmResourceId `
                -MetricName "Percentage CPU" `
                -StartTime $startTime `
                -EndTime $endTime `
                -Aggregation "Average"

            if ($null -ne $avgCPU) { 
                $vmMetrics.AvgCPUPercent = [math]::Round($avgCPU, 3) }

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
            if ($null -ne $vmSizeInfo) {
                $TotalAllocatedMemoryGiB = $vmSizeInfo.MemoryInMB / 1024
                $vmMetrics.TotalAllocatedMemoryGiB = [math]::Round($TotalAllocatedMemoryGiB, 2)
            }
           
            # Max Mem Used ( = Get MINIMUM available usage GiB)
            $availableMemoryBytes = Get-MetricValue `
                -ResourceId $vmResourceId `
                -MetricName "Available Memory Bytes" `
                -StartTime $startTime `
                -EndTime $endTime `
                -Aggregation "Minimum"

            if ($null -ne $availableMemoryBytes -and $null -ne $TotalAllocatedMemoryGiB) {
                $availableMemoryGiB = $availableMemoryBytes / 1GB
                $usedMemoryGiB = $TotalAllocatedMemoryGiB - $availableMemoryGiB
                $vmMetrics.MaxMemoryUsedGiB = [math]::Round($usedMemoryGiB, 3)
            }

            # AVERAGE memory usage for typical use
            $avgAvailableMemoryBytes = Get-MetricValue `
                -ResourceId $vmResourceId `
                -MetricName "Available Memory Bytes" `
                -StartTime $startTime `
                -EndTime $endTime `
                -Aggregation "Average"

            if ($null -ne $avgAvailableMemoryBytes -and $null -ne $TotalAllocatedMemoryGiB) {
                $avgAvailableMemoryGiB = $avgAvailableMemoryBytes / 1GB
                $avgUsedMemoryGiB = $TotalAllocatedMemoryGiB - $avgAvailableMemoryGiB
                $vmMetrics.AvgMemoryUsedGiB = [math]::Round($avgUsedMemoryGiB, 3)
            }

            # Network (Total over timegrain; rough Mbps estimation)
            $networkInBytes  = Get-MetricValue `
                -ResourceId $vmResourceId `
                -MetricName "Network In Total" `
                -StartTime $startTime `
                -EndTime $endTime `
                -Aggregation "Maximum"

            $networkOutBytes = Get-MetricValue `
                -ResourceId $vmResourceId `
                -MetricName "Network Out Total" `
                -StartTime $startTime `
                -EndTime $endTime `
                -Aggregation "Maximum"

            if ($null -ne $networkInBytes -and $null -ne $networkOutBytes) {
                #converting bytes to Mbps: (bytes x 8 bits) / (300 sec x 1,000,000)
                $vmMetrics.MaxNetworkBandwidthMbps = [math]::Round((($networkInBytes + $networkOutBytes) * 8) / (300 * 1000000), 2)
            }

            # Disk % 
            $diskBandwidth = Get-MetricValue `
                -ResourceId $vmResourceId `
                -MetricName "OS Disk Bandwidth Consumed Percentage" `
                -StartTime $startTime `
                -EndTime $endTime `
                -Aggregation "Maximum"

            if ($null -ne $diskBandwidth) { 
                $vmMetrics.MaxDiskBandwidthPercent = [math]::Round($diskBandwidth, 2) }

            # IOPS %
            $iops = Get-MetricValue `
                -ResourceId $vmResourceId `
                -MetricName "OS Disk IOPS Consumed Percentage" `
                -StartTime $startTime `
                -EndTime $endTime `
                -Aggregation "Maximum"

            if ($null -ne $iops) { 
                $vmMetrics.MaxIOPSPercent = [math]::Round($iops, 2) }

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

try {
    if ($metricsResults.Count -gt 0) {
        $metricsResults `
            | Sort-Object SubscriptionName, ResourceGroup, VMName `
            | Export-Csv -Path $metricsCsvPath -NoTypeInformation -Encoding UTF8
        Write-Host "Metrics CSV: $metricsCsvPath  (rows: $($metricsResults.Count))" -ForegroundColor Green
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
    Write-Host ""

} catch {
    Write-Error "Failed to export CSV: $($_.Exception.Message)"
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
