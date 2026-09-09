# AWS EC2 CloudWatch Metrics Collector

Collects 30 days of CPU, memory, network, disk, and IOPS metrics for every EC2 instance in one
AWS account (all regions or a single region) and writes an Excel workbook plus an inventory CSV.

Scripts:

- `aws-ec2-metrics.py`: the metrics collector. This page is mostly about it.
- `aws_commitments.py`: exports active Reserved Instances and Savings Plans. See
  [Commitment data](#commitment-data-reserved-instances-and-savings-plans).

## Prerequisites

- **Python 3.9+** with `pip`.
- **AWS credentials** for the target account, configured any way boto3 understands:
  `aws configure`, `aws sso login`, an `AWS_PROFILE`, environment variables, or an instance role.
  Alternatively run from **AWS CloudShell**, which is pre-authenticated and has Python and boto3
  preinstalled (see [Running from CloudShell](#running-from-cloudshell)).
- Python packages:

  ```bash
  pip3 install -r requirements.txt
  ```

  (`boto3`, `pandas`, `openpyxl`.)

### IAM permissions

Read-only. Attach a policy with at least:

| Service | Actions |
|---|---|
| EC2 | `ec2:DescribeInstances`, `ec2:DescribeRegions`, `ec2:DescribeInstanceTypes` |
| CloudWatch | `cloudwatch:GetMetricStatistics`, `cloudwatch:ListMetrics` |
| STS | `sts:GetCallerIdentity` |
| IAM (optional) | `iam:ListAccountAliases` (only used to fill `AccountAlias`; falls back to `N/A`) |

The managed policy `ReadOnlyAccess` covers all of these.

### Memory metrics need the CloudWatch Agent

EC2 publishes no memory metrics on its own. The script reads `mem_used_percent` from the
`CWAgent` namespace, which only exists where the CloudWatch Agent is installed and configured
to emit memory. Instances without it get `CWAgent not installed` in the memory columns and the
rest of the row is still filled. Deploying the agent is optional and has a cost, roughly
$0.30 per custom metric per month plus log ingestion. Agree that with the account owner before
rolling it out purely for this assessment.

## Run it

```bash
python3 aws-ec2-metrics.py
```

The script asks two questions:

1. `Scan all AWS regions? (yes/no)`. `yes` enumerates every enabled region and scans each.
2. If `no`: `Enter the AWS region to scan (e.g., eu-west-1)`.

Per instance it makes around 9 CloudWatch calls. Expect roughly 1 to 2 seconds per instance
per region.

The look-back window (30 days) and the sample period (30 minutes) are fixed in the script.
CloudWatch returns at most 1,440 datapoints per request, so a shorter period over 30 days would
be truncated. Basic monitoring stores 5-minute samples; the 30-minute statistics are computed
from those.

### Running from CloudShell

1. Open **CloudShell** from the AWS Console toolbar, in the region you want to work from. The
   script itself prompts for the region(s) to scan, so this choice does not limit the run.
2. Use the **Actions** menu (top right of the CloudShell panel) and **Upload file** to upload
   `aws-ec2-metrics.py`.
3. Confirm it arrived with `ls`, then run it:

   ```bash
   pip3 install --user pandas openpyxl
   python3 aws-ec2-metrics.py
   ```

4. When it finishes, use **Actions** and **Download file** with the path
   `instance_metrics.xlsx` to retrieve the workbook. Do the same for `instance_inventory.csv`.

CloudShell sessions use the credentials of the signed-in console user, so the same IAM
permissions apply.

### Multiple accounts

Run the script once per account. With named profiles:

```bash
AWS_PROFILE=prod python3 aws-ec2-metrics.py
```

Rename the output between runs (see below), otherwise the next run overwrites it.

## Output

Two files are written to the **current working directory**, with fixed names:

- `instance_metrics.xlsx`. One row per instance with specs and all metrics. This is the file to
  send back.
- `instance_inventory.csv`. Inventory-only subset (no metrics).

Both are **overwritten on every run**. Before sending, rename the workbook so it identifies the
account, for example `instance_metrics_<account-id>.xlsx`.

### `instance_metrics.xlsx` columns

| Column | Description |
|---|---|
| `AccountID` | 12-digit AWS account ID |
| `AccountAlias` | IAM account alias, or `N/A` |
| `Region` | Region scanned |
| `InstanceName` | Value of the `Name` tag, or `N/A` |
| `InstanceId` | EC2 instance ID |
| `Status` | EC2 state (`running`, `stopped`, ...) |
| `Platform` | `Windows` if EC2 reports it, otherwise `Linux` |
| `InstanceType` | Instance type, e.g. `m6i.large` |
| `Spec_vCPU_Count` | Default vCPUs for the type |
| `Spec_MaxMemory_GiB` | Memory for the type, GiB |
| `Avg CPU (%)`, `Max CPU (%)` | Mean of 30-minute averages, and peak 30-minute maximum, over 30 days |
| `Avg Mem (%)`, `Max Mem (%)` | Same, from the CloudWatch Agent `mem_used_percent` metric. `CWAgent not installed` when the agent is absent |
| `Max Network Ingress (Gbps)` | Peak `NetworkIn` converted to gigabits per second |
| `Max Network Egress (Gbps)` | Peak `NetworkOut` converted to gigabits per second |
| `Max Network Peak (Gbps)` | Peak of in + out summed at matching timestamps |
| `Max Disk BW (MB/s)` | Peak of `EBSReadBytes` + `EBSWriteBytes`, MiB per second |
| `Max IOPS (Ops/sec)` | Peak of `EBSReadOps` + `EBSWriteOps`, operations per second |

Rate conversions divide the 30-minute period totals by 1800 seconds. Instances with no
CloudWatch data in the window (e.g. stopped for the whole month) show `0`.

### `instance_inventory.csv` columns

`InstanceName`, `AccountID`, `AccountAlias`, `Region`, `Status`, `Platform`, `InstanceSize`,
`Spec_vCPU_Count`, `Spec_MaxMemory_GiB`.

## Commitment data (Reserved Instances and Savings Plans)

Moving to a different instance type (for example `m5` to `m5a`) changes the instance family, which
affects how existing Reserved Instances and Savings Plans apply. The assessment therefore also
needs an inventory of active commitments. This is a coverage check only, not a financial
analysis of the commitments.

**Option A: script.** Run `aws_commitments.py` from the **management (payer) account** of the
billing group so that Savings Plans are included. From a member account only Reserved
Instances are returned.

```bash
python3 aws_commitments.py
```

It writes `commitments.csv` to the current directory with one row per active Reserved Instance
and Savings Plan: type, ID, instance type and family, quantity or hourly commitment, region,
start, end, and offering details. Required permissions: `ec2:DescribeReservedInstances` and
`savingsplans:DescribeSavingsPlans`.

**Option B: console export.**

1. EC2 Console, **Reserved Instances**, filter to active, export the table.
2. Billing and Cost Management Console, **Savings Plans**, **Inventory**, export. This view is
   only available in the management account.

Send `commitments.csv` or the two console exports together with the metrics workbook.

## Alternatives to the script

The script is the recommended method. Manual collection through the CloudWatch console is
possible but impractical above roughly 20 instances, since every metric has to be read per
instance and typed into the results template. If the estate is already monitored by a
third-party observability platform (Datadog, Dynatrace, or similar), contact Crayon or
SoftwareOne for the data template and the fields to export from it.

## Notes and limitations

- **Memory needs the CloudWatch Agent** (see above). The script looks for `mem_used_percent` in
  the `CWAgent` namespace with an `InstanceId` dimension. Agents configured with a different
  dimension set, or a custom namespace, are not found.
- **Disk metrics cover EBS only**, via the instance-level `EBSReadBytes` / `EBSWriteBytes` /
  `EBSReadOps` / `EBSWriteOps` metrics in the `AWS/EC2` namespace. Instance-store volumes are not
  included, and instance types that do not publish these instance-level metrics show `0`.
- **Stopped instances are included** with zero metrics so the inventory is complete.
- Scanning **all regions** takes noticeably longer because every region is queried even if empty.

## Troubleshooting

- `Error creating AWS session` / `Unable to locate credentials`: run `aws configure` or
  `aws sso login`, or set `AWS_PROFILE`.
- `Error retrieving account information`: the credentials lack `sts:GetCallerIdentity`, or the
  session has expired.
- `Error retrieving regions`: missing `ec2:DescribeRegions`, or the region entered is not enabled
  on the account.
- `Error saving results`: install `pandas` and `openpyxl` (`pip3 install -r requirements.txt`).
- Python 3.12+ prints a `DeprecationWarning` about `datetime.utcnow()`. It is harmless.

## License

Copyright 2026 SoftwareOne AG. Apache License 2.0, see the repository [LICENSE](../LICENSE).
