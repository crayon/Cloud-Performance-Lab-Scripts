"""
AWS EC2 CloudWatch Metrics Script

Description:
- Collects essential CloudWatch metrics for EC2 instances
- Time range: last 30 days
- Period: 30 minutes (1800s)
- Region: asks user to scan all regions or specify one
- Exports results to instance_metrics.xlsx

Metrics exported:
- Avg CPU (%)
- Max CPU (%)
- Avg Mem (%) (requires CloudWatch Agent)
- Max Mem (%) (requires CloudWatch Agent)
- Max Network Ingress (Gbps)
- Max Network Egress (Gbps)
- Max Network Peak (Gbps)
- Max Disk BW (MB/s)
- Max IOPS (Ops/sec)
"""

# ---------------------------------------------------------------------------
# Changes in v2.1 (vs v2.0). No change to prompts, filenames, columns or order.
#
# 1. describe_instances is now paginated. Previously it read only the first
#    page (~1000 instances per region) and silently dropped the remainder.
#
# 2. list_metrics is now paginated. Previously it read only the first page
#    (500 metrics), so instances beyond it falsely reported
#    "CWAgent not installed" when the agent was in fact running.
#
# 3. Output files are now written unconditionally, including when a run finds
#    no instances. Previously nothing was written, leaving the previous run's
#    files on disk to be renamed and sent as this account's output.
# ---------------------------------------------------------------------------

import os
import boto3
import pandas as pd
from datetime import datetime, timedelta

METRICS_FILE = 'instance_metrics.xlsx'
INVENTORY_FILE = 'instance_inventory.csv'

# ---------------- CloudWatch metric helper ----------------
def get_metrics(cw_client, namespace, metric_name, dimensions, statistics, period, days):
    """Fetch CloudWatch metrics with error handling"""
    try:
        start_time = datetime.utcnow() - timedelta(days=days)
        end_time = datetime.utcnow()

        resp = cw_client.get_metric_statistics(
            Namespace=namespace,
            MetricName=metric_name,
            Dimensions=dimensions,
            StartTime=start_time,
            EndTime=end_time,
            Period=period,
            Statistics=statistics
        )

        return resp.get('Datapoints', [])
    
    except Exception as e:
        print(f"  ⚠️  Error fetching {metric_name}: {e}")
        return []

# ---------------- Locate CWAgent memory dimensions ----------------
def find_cwagent_dimensions(cw_client, instance_id):
    """Find CloudWatch Agent memory metric dimensions"""
    try:
        # Paginated: list_metrics returns 500 metrics per page. Without this,
        # instances beyond the first page falsely report "CWAgent not installed".
        paginator = cw_client.get_paginator('list_metrics')

        for page in paginator.paginate(
            Namespace='CWAgent',
            MetricName='mem_used_percent'
        ):
            for m in page['Metrics']:
                dims = {d['Name']: d['Value'] for d in m['Dimensions']}
                if dims.get('InstanceId') == instance_id:
                    return [{'Name': k, 'Value': v} for k, v in dims.items()]

        return None
    
    except Exception as e:
        print(f"  ⚠️  Error checking CloudWatch Agent: {e}")
        return None

# ---------------- Temporal alignment helper ----------------
def align_and_sum_metrics(metric_a, metric_b):
    """
    Aligns two metric datasets by timestamp and sums their values.
    Returns list of combined values at matching timestamps.
    """
    try:
        combined = []
        
        # Create timestamp lookup for metric_b
        metric_b_dict = {d['Timestamp']: d.get('Maximum', 0) for d in metric_b}
        
        for datapoint_a in metric_a:
            timestamp = datapoint_a['Timestamp']
            value_a = datapoint_a.get('Maximum', 0)
            
            # Find matching timestamp in metric_b
            if timestamp in metric_b_dict:
                value_b = metric_b_dict[timestamp]
                combined.append(value_a + value_b)
        
        return combined
    
    except Exception as e:
        print(f"  ⚠️  Error aligning metrics: {e}")
        return []

def main():
    print(__doc__)

    PERIOD = 1800
    DAYS = 30

    try:
        session = boto3.Session()
    except Exception as e:
        print(f"❌ Error creating AWS session: {e}")
        print("Please ensure AWS credentials are configured (aws configure)")
        return

    # ---------------- Account info ----------------
    try:
        sts = session.client("sts")
        iam = session.client("iam")

        account_id = sts.get_caller_identity()["Account"]

        try:
            aliases = iam.list_account_aliases()["AccountAliases"]
            account_alias = aliases[0] if aliases else "N/A"
        except:
            account_alias = "N/A"
    
    except Exception as e:
        print(f"❌ Error retrieving account information: {e}")
        return

    # ---------------- Region selection ----------------
    all_regions_choice = input("Scan all AWS regions? (yes/no): ").strip().lower()

    try:
        if all_regions_choice in ['yes', 'y']:
            ec2_client = session.client('ec2')
            regions = [r['RegionName'] for r in ec2_client.describe_regions()['Regions']]
        else:
            regions = [input("Enter the AWS region to scan (e.g., eu-west-1): ").strip()]
    except Exception as e:
        print(f"❌ Error retrieving regions: {e}")
        return

    results = []
    inventory_rows = []

    # Cache instance specs so we only query AWS once per type
    instance_type_cache = {}

    for REGION in regions:
        print(f"\n=== Scanning region: {REGION} ===")

        try:
            ec2 = session.client('ec2', region_name=REGION)
            cw = session.client('cloudwatch', region_name=REGION)
        except Exception as e:
            print(f"❌ Error connecting to region {REGION}: {e}")
            continue

        try:
            # Paginated: describe_instances caps at ~1000 results per page and
            # returns a NextToken. Without this, larger estates are silently truncated.
            paginator = ec2.get_paginator('describe_instances')
            reservations = []
            for page in paginator.paginate():
                reservations.extend(page['Reservations'])
        except Exception as e:
            print(f"❌ Error retrieving instances in {REGION}: {e}")
            continue

        print(f"  Found {sum(len(r['Instances']) for r in reservations)} instances")

        for reservation in reservations:
            for instance in reservation['Instances']:

                try:
                    instance_id = instance['InstanceId']
                    instance_type = instance['InstanceType']
                    state = instance['State']['Name']

                    # Instance Name tag
                    name = "N/A"
                    for tag in instance.get("Tags", []):
                        if tag["Key"] == "Name":
                            name = tag["Value"]

                    # Platform detection (Windows explicitly set, Linux implied)
                    platform = instance.get("Platform", "Linux").capitalize()

                    # ---------------- Instance hardware specs ----------------
                    if instance_type not in instance_type_cache:
                        try:
                            spec = ec2.describe_instance_types(
                                InstanceTypes=[instance_type]
                            )['InstanceTypes'][0]

                            vcpus = spec['VCpuInfo']['DefaultVCpus']
                            memory_gib = round(spec['MemoryInfo']['SizeInMiB'] / 1024, 2)

                            instance_type_cache[instance_type] = (vcpus, memory_gib)
                        except Exception as e:
                            print(f"  ⚠️  Error fetching specs for {instance_type}: {e}")
                            vcpus = 'Error'
                            memory_gib = 'Error'
                            instance_type_cache[instance_type] = (vcpus, memory_gib)
                    else:
                        vcpus, memory_gib = instance_type_cache[instance_type]

                    print(f"\n  Processing {instance_id} ({instance_type}) - {state}")

                    ec2_dims = [{'Name': 'InstanceId', 'Value': instance_id}]

                    # ---------------- CPU ----------------
                    cpu_data = get_metrics(
                        cw, 'AWS/EC2', 'CPUUtilization',
                        ec2_dims, ['Average', 'Maximum'],
                        PERIOD, DAYS
                    )

                    avg_cpu = round(sum(d.get('Average', 0) for d in cpu_data) / len(cpu_data), 2) if cpu_data else 0
                    max_cpu = round(max((d.get('Maximum', 0) for d in cpu_data), default=0), 2)

                    # ---------------- Memory ----------------
                    mem_dims = find_cwagent_dimensions(cw, instance_id)

                    if mem_dims:
                        mem_data = get_metrics(
                            cw, 'CWAgent', 'mem_used_percent',
                            mem_dims, ['Average', 'Maximum'],
                            PERIOD, DAYS
                        )

                        avg_mem = round(sum(d.get('Average', 0) for d in mem_data) / len(mem_data), 2) if mem_data else 0
                        max_mem = round(max((d.get('Maximum', 0) for d in mem_data), default=0), 2)
                    else:
                        avg_mem = 'CWAgent not installed'
                        max_mem = 'CWAgent not installed'

                    # ---------------- Network (with temporal alignment) ----------------
                    net_in = get_metrics(cw, 'AWS/EC2', 'NetworkIn', ec2_dims, ['Maximum'], PERIOD, DAYS)
                    net_out = get_metrics(cw, 'AWS/EC2', 'NetworkOut', ec2_dims, ['Maximum'], PERIOD, DAYS)

                    # Calculate separate ingress and egress peaks
                    max_ingress_bytes = max((d.get('Maximum', 0) for d in net_in), default=0)
                    max_egress_bytes = max((d.get('Maximum', 0) for d in net_out), default=0)
                    
                    # Align by timestamp and sum, then find peak
                    combined_network = align_and_sum_metrics(net_in, net_out)
                    max_peak_bytes = max(combined_network, default=0)

                    # Convert to Gbps (bytes * 8 bits / period seconds / 1e9 for Gbps)
                    max_network_ingress = round(max_ingress_bytes * 8 / PERIOD / 1e9, 6)
                    max_network_egress = round(max_egress_bytes * 8 / PERIOD / 1e9, 6)
                    max_network_peak = round(max_peak_bytes * 8 / PERIOD / 1e9, 6)

                    # ---------------- Disk (with temporal alignment) ----------------
                    ebs_read_bytes = get_metrics(cw, 'AWS/EC2', 'EBSReadBytes', ec2_dims, ['Maximum'], PERIOD, DAYS)
                    ebs_write_bytes = get_metrics(cw, 'AWS/EC2', 'EBSWriteBytes', ec2_dims, ['Maximum'], PERIOD, DAYS)

                    # Align by timestamp and sum, then find peak
                    combined_disk = align_and_sum_metrics(ebs_read_bytes, ebs_write_bytes)
                    max_disk_bytes = max(combined_disk, default=0)

                    # Convert to MB/s (bytes / period seconds / 1024 / 1024 for MB)
                    max_disk_bw = round(max_disk_bytes / PERIOD / 1024 / 1024, 2)

                    # ---------------- IOPS (with temporal alignment) ----------------
                    ebs_read_ops = get_metrics(cw, 'AWS/EC2', 'EBSReadOps', ec2_dims, ['Maximum'], PERIOD, DAYS)
                    ebs_write_ops = get_metrics(cw, 'AWS/EC2', 'EBSWriteOps', ec2_dims, ['Maximum'], PERIOD, DAYS)

                    # Align by timestamp and sum, then find peak
                    combined_ops = align_and_sum_metrics(ebs_read_ops, ebs_write_ops)
                    max_ops = max(combined_ops, default=0)

                    # Convert to IOPS (operations / period seconds)
                    max_iops = round(max_ops / PERIOD, 2)

                    # ---------------- Result rows ----------------
                    row = {
                        'AccountID': account_id,
                        'AccountAlias': account_alias,
                        'Region': REGION,
                        'InstanceName': name,
                        'InstanceId': instance_id,
                        'Status': state,
                        'Platform': platform,
                        'InstanceType': instance_type,
                        'Spec_vCPU_Count': vcpus,
                        'Spec_MaxMemory_GiB': memory_gib,
                        'Avg CPU (%)': avg_cpu,
                        'Max CPU (%)': max_cpu,
                        'Avg Mem (%)': avg_mem,
                        'Max Mem (%)': max_mem,
                        'Max Network Ingress (Gbps)': max_network_ingress,
                        'Max Network Egress (Gbps)': max_network_egress,
                        'Max Network Peak (Gbps)': max_network_peak,
                        'Max Disk BW (MB/s)': max_disk_bw,
                        'Max IOPS (Ops/sec)': max_iops
                    }

                    results.append(row)

                    inventory_rows.append({
                        'InstanceName': name,
                        'AccountID': account_id,
                        'AccountAlias': account_alias,
                        'Region': REGION,
                        'Status': state,
                        'Platform': platform,
                        'InstanceSize': instance_type,
                        'Spec_vCPU_Count': vcpus,
                        'Spec_MaxMemory_GiB': memory_gib
                    })

                    print(f"  ✓ Processed successfully")

                except Exception as e:
                    print(f"  ❌ Error processing instance {instance.get('InstanceId', 'unknown')}: {e}")
                    continue

    # ---------------- Export results ----------------
    try:
        # Written unconditionally, including when empty. A run that finds nothing
        # must not leave a previous account's files on disk to be renamed and sent
        # as this account's output.
        # Column order comes from the row dict as before, unchanged.
        pd.DataFrame(results).to_excel(METRICS_FILE, index=False)
        pd.DataFrame(inventory_rows).to_csv(INVENTORY_FILE, index=False)

        print(f"\n{'='*60}")
        if results:
            print(f"✓ SUCCESS: Processed {len(results)} instances")
        else:
            print("⚠️  NO INSTANCES FOUND, OR ALL INSTANCES FAILED PROCESSING")
            print("   Empty files have been written so they cannot be mistaken")
            print("   for output from a previous run. Do not send these.")
        print(f"✓ Metrics:   {os.path.abspath(METRICS_FILE)}")
        print(f"✓ Inventory: {os.path.abspath(INVENTORY_FILE)}")
        print(f"{'='*60}\n")
    
    except Exception as e:
        print(f"\n❌ Error saving results: {e}")
        print("Data collected but export failed. Check pandas/openpyxl installation.")

if __name__ == '__main__':
    main()