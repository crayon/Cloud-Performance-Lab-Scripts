# Azure VM Metrics & Availability Assessment

Collects CPU, memory, network, disk, IOPS, and (optionally) availability metrics for every VM
across all enabled subscriptions in an Azure tenant, and writes flat CSVs.

The script is **cross-platform** PowerShell — same command on Windows, macOS, and Linux.
Required Az modules are auto-installed in the user scope on first run.

## Prerequisite (one time)

Install **PowerShell 7+** if it isn't already on the machine. The script enforces this and
will stop with a clear message on Windows PowerShell 5.1.

- **Windows** — `winget install Microsoft.PowerShell` (or download the MSI from
  <https://github.com/PowerShell/PowerShell/releases>)
- **macOS** — `brew install --cask powershell`
- **Linux** — see <https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux>

Verify with `pwsh --version` (should report 7.x or newer).

## Run it

```powershell
pwsh -File ./metrics_availability_assessment.ps1
```

On first run the script installs `Az.Accounts`, `Az.Compute`, and `Az.Monitor` to your user
profile. This downloads roughly 600 MB and can take several minutes — that's normal.

> **Stricter change-control environments:** the auto-install runs `Install-Module` from the
> PowerShell Gallery and briefly sets PSGallery as a trusted repository for the current user.
> If your organisation restricts software installation or external package sources, review
> the modules and install them separately ahead of time under an approved process, then run
> with `-SkipModuleCheck` so the script performs no installation:
> ```powershell
> Install-Module Az.Accounts, Az.Compute, Az.Monitor -Scope CurrentUser
> pwsh -File ./metrics_availability_assessment.ps1 -SkipModuleCheck
> ```

Common variants:

```powershell
pwsh -File ./metrics_availability_assessment.ps1 -DaysBack 14 -IncludeAvailability
pwsh -File ./metrics_availability_assessment.ps1 -TenantId <tenant-guid>
pwsh -File ./metrics_availability_assessment.ps1 -UseDeviceAuthentication   # SSH / headless
pwsh -File ./metrics_availability_assessment.ps1 -VMNames vm-prd-01,vm-prd-02
pwsh -File ./metrics_availability_assessment.ps1 -OutputPath ~/assessments
```

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-DaysBack` | `30` | Look-back window in days. Azure retains VM metrics for 30 days; values above 30 will produce empty cells for the older portion and the script will warn. |
| `-OutputPath` | current dir | Where the CSVs and run log are written. Created if it doesn't exist. |
| `-IncludeAvailability` | off | Also collect VM availability data. |
| `-TenantId` | current context | Restrict to a specific tenant. |
| `-VMNames` | all | Comma-separated VM names to include. |
| `-UseDeviceAuthentication` | off | Device-code login for headless / SSH sessions. |
| `-SkipModuleCheck` | off | Skip auto-install of Az modules (faster on warm machines, or if a corporate policy blocks `Install-Module`). |

## Output

Three timestamped files are written to `-OutputPath`:

- `VM_Metrics_yyyyMMdd_HHmmss.csv` — one row per VM with sizing, CPU, memory, network, disk, IOPS.
- `VM_Availability_yyyyMMdd_HHmmss.csv` — only with `-IncludeAvailability`.
- `VM_Assessment_yyyyMMdd_HHmmss.log` — full transcript of the run. Send this if you need help diagnosing a failure. **Review and sanitise this before sharing** — see the note below.

> **Transcript may contain sensitive details.** The `.log` is a verbatim transcript of the
> console session, so beyond the data in the CSVs it can capture the signed-in account
> identity (UPN / email), tenant and subscription IDs and names, every in-scope resource
> group and VM name, the output path (which may include a local username), and raw Azure
> error messages — which sometimes include role-assignment details, principal IDs, or
> resource paths. None of it is workload or guest data, but treat the file as internal.
> Open it, review the contents, and redact anything your organisation considers sensitive
> before sending it on.

## Data collected

The script reads Azure Resource Manager metadata and Azure Monitor metrics only. It does **not**
read into guest operating systems, application data, file contents, or any customer workload data.
Every field below is written to the CSVs in plain text.

**`VM_Metrics_*.csv`**

| Field | Description |
|---|---|
| `SubscriptionName` | Display name of the subscription |
| `SubscriptionId` | Subscription GUID |
| `ResourceGroup` | Resource group the VM belongs to |
| `VMName` | VM resource name |
| `Location` | Azure region |
| `VMSize` | VM SKU (e.g. `Standard_D4s_v5`) |
| `PowerState` | Running / deallocated / stopped / unknown |
| `OSType` | Windows or Linux (from the OS disk profile) |
| `MaxCPUPercent`, `AvgCPUPercent` | Peak and average CPU utilisation over the window |
| `TotalCPUCores` | vCPU count for the SKU |
| `MaxMemoryUsedGiB`, `AvgMemoryUsedGiB` | Peak and average memory used (requires Azure Monitor Agent) |
| `TotalAllocatedMemoryGiB` | Memory allocated to the SKU |
| `MaxNetworkBandwidthMbps` | Peak combined in/out network throughput (estimated) |
| `MaxDiskBandwidthPercent` | Peak OS disk bandwidth consumed as a percentage of the cap |
| `MaxIOPSPercent` | Peak OS disk IOPS consumed as a percentage of the cap |
| `CollectionPeriodDays`, `CollectionStartDate`, `CollectionEndDate` | The look-back window used for the run |

**`VM_Availability_*.csv`** (only with `-IncludeAvailability`)

| Field | Description |
|---|---|
| `SubscriptionName`, `SubscriptionId`, `ResourceGroup`, `VMName`, `Location`, `PowerState` | Same identifiers as above |
| `AvailabilityPercent` | Availability over the window |
| `UptimeCalculationMethod` | Which source produced the figure (VM Availability metric, Activity Log estimate, or none) |
| `CollectionPeriodDays`, `CollectionStartDate`, `CollectionEndDate` | The look-back window used for the run |

## Permissions

The signed-in account needs, at minimum:

- **Reader** on each in-scope subscription
- `Microsoft.Insights/metrics/read`
- `Microsoft.Compute/virtualMachines/read` (and `instanceView/read` for accurate power state)

If a subscription is missing access the script logs a warning and continues with the next one
rather than aborting.

## Resilience built in

- **PowerShell 7 enforced** with `#Requires -Version 7.0`.
- **Az modules auto-installed** on first run; a clear remediation hint is shown if install is blocked.
- **Throttling-aware metric calls** retry up to 4 times with exponential backoff on HTTP 429 / timeouts.
- **Graceful per-subscription failures** — a tenant-wide run keeps going if one subscription denies access.
- **`Get-AzVM -Status` fallback** — if `instanceView/read` is missing, the script falls back to `Get-AzVM` and marks PowerState as `Unknown`.
- **Sign-in failures abort early** with a hint to retry with `-UseDeviceAuthentication`.
- **Run log** captured to a `.log` file alongside the CSVs.

## Q&A

**Is anything sent outside my tenant?**
No. The script runs locally, calls Azure Resource Manager with your credentials, and writes CSVs to disk. Nothing leaves the machine.

**What credentials does it use?**
Whatever you sign in with at the `Connect-AzAccount` prompt — interactive browser by default, device code with `-UseDeviceAuthentication`. No service principal or secret is required.

**Will it change anything in my Azure environment?**
No. All calls are read-only (`Get-AzSubscription`, `Get-AzVM`, `Get-AzMetric`, `Get-AzActivityLog`). The only writes are to your local output folder.

**How long will it take?**
Roughly 2–5 seconds per VM, plus the one-time module install on first run. A 200-VM tenant typically completes in 10–20 minutes.

**Can I run it against just one subscription?**
Set the context first, then pass `-SkipModuleCheck` if modules are already loaded:
```powershell
Set-AzContext -SubscriptionId <sub-guid>
pwsh -File ./metrics_availability_assessment.ps1 -TenantId <tenant-guid>
```
The tenant filter combined with the active context effectively scopes the run.

**Why does `MaxMemoryUsedGiB` say nothing for some VMs?**
That column relies on the `Available Memory Bytes` guest metric, which only emits when the **Azure Monitor Agent** (or legacy diagnostics extension) is installed on the VM. CPU, network, and host-disk metrics don't need an agent.

**Why is `AvailabilityPercent` blank?**
The preview `VmAvailabilityMetric` isn't published in every region or for every VM SKU. The script falls back to an Activity Log estimate; if that also returns nothing, the column stays empty.

**Can I run it more often than once?**
Yes — every run writes new timestamped files, so previous output is never overwritten.

**It says "PowerShell 7.0 or later is required". Now what?**
You're in Windows PowerShell 5.1 (the blue console). Install pwsh 7 once (`winget install Microsoft.PowerShell`) and launch with `pwsh -File ...` from any terminal.

**`Install-Module` is blocked by my company. What can I do?**
Have an admin install the modules once, or install them under your user profile from a network you control:
```powershell
Install-Module Az.Accounts, Az.Compute, Az.Monitor -Scope CurrentUser
```
Then run with `-SkipModuleCheck` so the script doesn't re-attempt installation.

**One subscription is throwing errors and the rest look fine.**
That's expected behaviour — per-subscription failures are logged and skipped. Check the `VM_Assessment_*.log` file for the specific message (usually a missing role assignment).

**How do I share results with Crayon?**
Send the two CSVs and the matching `.log` file from `-OutputPath`. The log is a full transcript so we can reproduce any issue without needing live access. Review and sanitise the `.log` first (see [Output](#output)) — it can contain account, tenant, and subscription identifiers.

## Troubleshooting

- **`This script requires PowerShell 7.0 or later`** — you launched it in Windows PowerShell 5.1. Install pwsh 7+ (see prerequisite above) and run with `pwsh -File ...`.
- **No browser available** — run with `-UseDeviceAuthentication` and follow the device-code URL printed in the console.
- **`Install-Module` denied** (corporate policy) — install once manually under an account that can, then run with `-SkipModuleCheck`:
  ```powershell
  Install-Module Az.Accounts, Az.Compute, Az.Monitor -Scope CurrentUser
  ```
- **Empty memory / disk metrics for some VMs** — Azure requires the Azure Monitor agent for guest-level memory and disk metrics. Host-level CPU and network always populate.
- **`-DaysBack` warning** — Azure caps VM metric retention at 30 days; older days will be empty.
- **Script feels stuck on first run** — it's downloading the Az modules (~600 MB). Subsequent runs are fast.

## License

Copyright 2026 SoftwareOne AG

This software and associated documentation files (the "Software") is licensed under the Apache License, Version 2.0 (the "License"). You are permitted to use the Software in accordance with the terms of the License. Please see the License for the specific language governing permissions and limitations under the License.

You can obtain a copy of the License at <http://www.apache.org/licenses/LICENSE-2.0>.

THE SOFTWARE DISTRIBUTED UNDER THE LICENSE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
