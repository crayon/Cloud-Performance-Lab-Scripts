"""
AWS Commitment Inventory Script

Exports active Reserved Instances and Savings Plans to commitments.csv.
Used alongside the EC2 metrics export to identify instance families where a
change of instance type would affect existing commitment coverage.

Savings Plans are only visible from the management (payer) account of the
billing group. Run from that account to capture them; from a member account
only Reserved Instances are returned.
"""

import boto3
import csv

# Initialize AWS clients
ec2 = boto3.client('ec2')
sp = boto3.client('savingsplans')

# Fetch Reserved Instances (active only)
ris = ec2.describe_reserved_instances(
    Filters=[{'Name': 'state', 'Values': ['active']}]
)

# Fetch Savings Plans (active only)
sps_response = sp.describe_savings_plans(states=['active'])

# Write to CSV
with open('commitments.csv', 'w', newline='') as f:
    writer = csv.writer(f)

    writer.writerow([
        'CommitmentType', 'CommitmentId', 'InstanceType', 'InstanceFamily',
        'Quantity', 'HourlyCommitment', 'Region', 'Start', 'End', 'OfferingDetails'
    ])

    # Write Reserved Instances
    for ri in ris.get('ReservedInstances', []):
        writer.writerow([
            'Reserved Instance',
            ri['ReservedInstancesId'],
            ri['InstanceType'],
            ri['InstanceType'].split('.')[0],
            ri['InstanceCount'],
            '',
            ri.get('AvailabilityZone', ''),
            ri['Start'],
            ri['End'],
            f"{ri['OfferingClass']}, {ri['OfferingType']}"
        ])

    # Write Savings Plans
    for s in sps_response.get('savingsPlans', []):
        writer.writerow([
            'Savings Plan',
            s['savingsPlanId'],
            '',
            s.get('ec2InstanceFamily', 'Any'),
            '',
            s['commitment'],
            s.get('region', 'Any'),
            s['start'],
            s['end'],
            s['savingsPlanType']
        ])

print("✓ commitments.csv created")
