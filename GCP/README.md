# GCP Compute Engine Metrics Collector

Collects CPU, memory, network, disk, and IOPS metrics for every Compute Engine instance in one
GCP project, records the CPU platform reported for each instance, and writes a single Excel
workbook.

Script: `gcp_metrics_collector.py`.

## Prerequisites

### IAM permissions

Read-only. The account running the script needs, on the target project:

| Service | Permissions |
|---|---|
| Compute Engine | `compute.instances.list`, `compute.instances.get`, `compute.machineTypes.get`, `compute.zones.list` |
| Cloud Monitoring | `monitoring.timeSeries.list` |
| Resource Manager | `resourcemanager.projects.get` (only used to fill `ProjectName`; falls back to `N/A`) |

The predefined roles **Compute Viewer** + **Monitoring Viewer** cover this. Project-level
**Viewer** also works.

### Python environment

**Option A: Google Cloud Shell (recommended).** Already authenticated, Python 3 and `gcloud`
preinstalled.

1. Open Cloud Shell from the Console.
2. Use the **More** menu (top right of the Cloud Shell panel) and **Upload** the script file.
3. Install the dependencies once:

   ```bash
   pip3 install --user google-cloud-compute google-cloud-monitoring google-cloud-resource-manager pandas openpyxl
   ```

**Option B: local machine.** Python 3.9+ and the gcloud CLI.

```bash
gcloud auth application-default login
gcloud config set project <project-id>
pip3 install -r requirements.txt
```

The script uses Application Default Credentials. Service-account JSON also works via
`GOOGLE_APPLICATION_CREDENTIALS`.

## Run it

```bash
python3 gcp_metrics_collector.py
```

Prompts, in order:

| Prompt | Default | Notes |
|---|---|---|
| `Enter GCP project ID` | current `gcloud` project, if set | Project **ID**, not display name |
| `Enter zone(s) separated by comma or 'all'` | `all` | `all` lists every zone in the project (100+) and scans each. Name specific zones to speed up small estates, e.g. `europe-west2-a,europe-west2-b` |
| `Enter time range in days` | `30` | 1 to 400. Cloud Monitoring keeps full-resolution data for 6 weeks and downsampled data for up to 24 months |
| `Enter alignment interval in minutes` | `1` | Bucket size used when computing peak network, disk, and IOPS rates. Larger values smooth peaks |
| `Skip stopped/terminated instances?` | `no` | `no` keeps them in the inventory with whatever metrics exist |

With more than 3 zones the script processes zones in parallel (up to 5 workers). Per-instance
progress is printed as it goes, and a summary with Ops Agent coverage is printed at the end.

Each instance costs 9 Monitoring API calls; budget roughly 1 to 3 seconds per instance.

### Multiple projects

Run the script once per project. Every run writes a separately named file, so nothing is
overwritten.

## Output

One file in the **current working directory**:

```
gcp_instance_metrics_<project-id>_<yyyyMMdd_HHmmss>.xlsx
```

In Cloud Shell, use the **More** menu and **Download** to retrieve it (enter the file name as
printed by the script). This is the file to send back.

### Columns

| Column | Description |
|---|---|
| `ProjectID` | Project ID |
| `ProjectName` | Project display name, or `N/A` |
| `Region` | Region derived from the zone |
| `Zone` | Zone |
| `InstanceName` | Instance name |
| `InstanceID` | Numeric instance ID (stored as text) |
| `InstanceState` | `RUNNING`, `TERMINATED`, `SUSPENDED`, ... |
| `Platform` | `Windows` if any attached disk carries a Windows licence, otherwise `Linux` |
| `MachineType` | Machine type name, e.g. `n2d-standard-4` or `e2-custom-2-9984` |
| `CPU_Platform` | CPU platform as reported by Compute Engine, or `Unknown` (see below) |
| `Spec_vCPU_Count` | Guest vCPUs for the machine type |
| `Spec_MaxMemory_GiB` | Memory for the machine type, GiB |
| `AvgCPU_Percent`, `MaxCPU_Percent` | Mean and peak of `instance/cpu/utilization`, as a percentage |
| `AvgMemory_Percent`, `MaxMemory_Percent` | Mean and peak of the Ops Agent `memory/percent_used` metric. `No Ops Agent` when no data exists |
| `OpsAgentInstalled` | `Yes` if memory data was found, else `No` |
| `MaxNetworkBW_BytesPerSec` | Peak of received + sent bytes per second at matching timestamps |
| `MaxNetworkBW_Mbps` | Same, in megabits per second (decimal) |
| `MaxDiskBW_BytesPerSec` | Peak of disk read + write bytes per second |
| `MaxDiskBW_MBps` | Same, in megabytes per second (decimal) |
| `MaxIOPS` | Peak of disk read + write operations per second |

If metric collection fails for an instance after retries, the identity and spec columns are
still written and the metric columns contain `ERROR`.

### CPU platform

`CPU_Platform` is the instance's `cpuPlatform` field exactly as Compute Engine reports it (for
example `Intel Cascade Lake`). Compute Engine usually reports it only for running instances, so
stopped or terminated instances typically show `Unknown`.

## Notes and limitations

- **Memory needs the Ops Agent** (or the legacy Monitoring agent). Compute Engine does not
  publish guest memory on its own. An instance with the agent installed but reporting 0% for
  the whole window is also shown as `No Ops Agent`.
- **Peaks depend on the alignment interval.** The default 1-minute buckets give the most
  faithful peak. CPU and memory use raw samples and are not affected.
- **Scanning `all` zones** issues a list call for every zone in the project before collection
  starts. For a small estate, naming the zones is much faster.
- The script prints a **retry warning** and moves on if a single API call fails three times.
  Check the console output for `⚠️` lines before sending the file.

## Troubleshooting

- `Error initializing GCP clients` / `DefaultCredentialsError`: run
  `gcloud auth application-default login`, or use Cloud Shell.
- `Error fetching zones` / `403`: the account lacks Compute Viewer on the project, or the
  Compute Engine API is not enabled.
- `Could not get project name`: missing `resourcemanager.projects.get`. Harmless, the column
  shows `N/A`.
- `ModuleNotFoundError: google.cloud`: install the packages with the `pip3 install` command
  above, into the same Python that runs the script.
- Python 3.12+ prints a `DeprecationWarning` about `datetime.utcnow()`. It is harmless.

## License

Copyright 2026 SoftwareOne AG. Apache License 2.0, see the repository [LICENSE](../LICENSE).
