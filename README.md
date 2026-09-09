# Cloud Performance Lab Scripts

Read-only metric collectors for the **Cloud Performance Lab batch optimization**. Each script inventories the
compute estate in one cloud, pulls 30 days of utilisation metrics from the native monitoring
service, and writes a flat file (Excel or CSV) that is sent back for analysis.

| Cloud | Folder | Script | Runtime | Output |
|---|---|---|---|---|
| AWS | [`AWS/`](AWS/README.md) | `aws-ec2-metrics.py` | Python 3 + boto3 | `instance_metrics.xlsx`, `instance_inventory.csv` |
| Azure | [`Azure/`](Azure/README.md) | `metrics_availability_assessment.ps1` | PowerShell 7 + Az modules | `VM_Metrics_*.csv`, `VM_Availability_*.csv` |
| GCP | [`GCP/`](GCP/README.md) | `gcp_metrics_collector.py` | Python 3 + google-cloud SDKs | `gcp_instance_metrics_<project>_*.xlsx` |

Each folder contains the script and a README with prerequisites, permissions, run steps, and a
description of every output column.

## What the scripts collect

All three follow the same pattern:

- **Inventory**: account/subscription/project, region, instance name and ID, power state, OS
  platform, machine size, vCPU count, and allocated memory.
- **CPU**: average and peak utilisation over the window.
- **Memory**: average and peak used, only where the cloud's guest agent is installed
  (CloudWatch Agent, Azure Monitor Agent, or Ops Agent). Otherwise a sentinel value is written.
- **Network**: peak combined throughput.
- **Disk**: peak bandwidth and peak IOPS.

They call only read-only APIs, write only to the local working directory, and never read into
the guest OS, application data, or customer workload data.

## Quick start

```bash
# AWS  (needs AWS credentials configured, e.g. `aws configure` or SSO)
cd AWS && pip3 install -r requirements.txt && python3 aws-ec2-metrics.py

# GCP  (easiest from Google Cloud Shell; locally needs `gcloud auth application-default login`)
cd GCP && pip3 install -r requirements.txt && python3 gcp_metrics_collector.py
```

```powershell
# Azure (PowerShell 7+; Az modules auto-install on first run)
cd Azure; pwsh -File ./metrics_availability_assessment.ps1 -IncludeAvailability
```

See the per-cloud README for prompts, parameters, permissions, and troubleshooting.

## Returning results

Send the output file(s) named in the table above. Review them first: they contain account,
subscription or project identifiers and every in-scope instance name. They contain no
credentials and no workload data.

## Repository layout

```
AWS/     EC2 collector + Reserved Instance / Savings Plan export (Python), README, requirements.txt
Azure/   VM collector (PowerShell), README
GCP/     Compute Engine collector (Python), README, requirements.txt
```

## License

Copyright 2026 SoftwareOne AG. Licensed under the Apache License, Version 2.0. See
[LICENSE](LICENSE) and [NOTICE](NOTICE).
