import os
import csv
from datetime import datetime, timedelta, timezone

import boto3

# -----------------------
# AWS clients
# -----------------------
cloudwatch = boto3.client('cloudwatch')
s3 = boto3.client('s3')
ec2 = boto3.client('ec2')

# -----------------------
# Config via environment
# -----------------------
BUCKET = os.environ['BUCKET_NAME']          # S3 bucket to write CSV files to
INSTANCE_ID = os.environ['INSTANCE_ID']     # EC2 instance to monitor
# Period (seconds) controls metric granularity:
# - 300 for Basic Monitoring (5-min)
PERIOD = int(os.environ.get('PERIOD_SECONDS', '300'))

print('The Lambda function has started...')

def lambda_handler(event, context):
    """
    Fetch the last 24h of EC2 metrics from CloudWatch for a single instance:
      - CPUUtilization (Average, Percent)
      - NetworkIn      (Sum, Bytes)
      - NetworkOut     (Sum, Bytes)

    Then write one CSV to S3 under a date-partitioned key:
      s3://<bucket>/ec2-metrics/YYYY/MM/DD/instance-<id>.csv

    CSV columns:
      timestamp,cpu_percent,network_in_bytes,network_out_bytes
    """
    # -----------------------
    # Time window: last 24 hours ending "now" (UTC, minute-rounded)
    # -----------------------
    end = datetime.now(timezone.utc).replace(second=0, microsecond=0)
    
    # NEW: find instance launch time (UTC)
    desc = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
    launch = desc['Reservations'][0]['Instances'][0]['LaunchTime']
    launch = launch.astimezone(timezone.utc).replace(second=0, microsecond=0)

    # want last 24h, but not earlier than launch
    desired_start = end - timedelta(days=1)
    start = max(desired_start, launch)

    # -----------------------
    # Prepare metric queries
    # - CPUUtilization uses Average (%)
    # - NetworkIn/Out use Sum (total bytes per period)
    # -----------------------
    dims = [{"Name": "InstanceId", "Value": INSTANCE_ID}]
    queries = [
        {
            "Id": "cpu",
            "MetricStat": {
                "Metric": {
                    "Namespace": "AWS/EC2",
                    "MetricName": "CPUUtilization",
                    "Dimensions": dims,
                },
                "Period": PERIOD,
                "Stat": "Average",
                "Unit": "Percent",
            },
            "ReturnData": True,
        },
        {
            "Id": "netin",
            "MetricStat": {
                "Metric": {
                    "Namespace": "AWS/EC2",
                    "MetricName": "NetworkIn",
                    "Dimensions": dims,
                },
                "Period": PERIOD,
                "Stat": "Sum",
                "Unit": "Bytes",
            },
            "ReturnData": True,
        },
        {
            "Id": "netout",
            "MetricStat": {
                "Metric": {
                    "Namespace": "AWS/EC2",
                    "MetricName": "NetworkOut",
                    "Dimensions": dims,
                },
                "Period": PERIOD,
                "Stat": "Sum",
                "Unit": "Bytes",
            },
            "ReturnData": True,
        },
    ]

    # -----------------------
    # Call CloudWatch once for all series
    # -----------------------
    resp = cloudwatch.get_metric_data(
        MetricDataQueries=queries,
        StartTime=start,
        EndTime=end,
        ScanBy="TimestampAscending",  # return oldest → newest
        MaxDatapoints=5000,
    )
    print('Successfully got the metrics')
    # -----------------------
    # Normalize results by timestamp
    # CloudWatch may return different timestamp sets per metric.
    # We build a dict keyed by ISO timestamp and fill each metric if present.
    # -----------------------
    series = {r["Id"]: r for r in resp.get("MetricDataResults", [])}

    # Helper: turn a single series into {iso_ts: value}
    def to_map(result):
        out = {}
        for t, v in zip(result.get("Timestamps", []), result.get("Values", [])):
            # Use ISO 8601 for stable CSV and downstream parsing
            out[t.isoformat()] = v
        return out

    cpu_map = to_map(series.get("cpu", {}))
    in_map = to_map(series.get("netin", {}))
    out_map = to_map(series.get("netout", {}))

    # Union of all timestamps (as sorted list)
    all_ts = sorted(set(cpu_map.keys()) | set(in_map.keys()) | set(out_map.keys()))

    # -----------------------
    # Build CSV rows
    # Note:
    #  - Missing values are written as empty cells to avoid inventing data.
    #  - For NetworkIn/Out we used Stat=Sum, so values are bytes PER PERIOD.
    # -----------------------
    rows = []
    header = ["timestamp", "cpu_percent", "network_in_bytes", "network_out_bytes"]
    rows.append(header)

    for ts in all_ts:
        cpu_val = _fmt(cpu_map.get(ts))
        in_val = _fmt(in_map.get(ts))
        out_val = _fmt(out_map.get(ts))
        rows.append([ts, cpu_val, in_val, out_val])

    # -----------------------
    # Write to S3 (one file per day)
    # Path is partitioned by date for easy Athena/BI consumption.
    # -----------------------
    key = f"ec2-metrics/{end.year}/{end.month:02d}/{end.day:02d}/instance-{INSTANCE_ID}.csv"
    body = _to_csv_bytes(rows)
    s3.put_object(Bucket=BUCKET, Key=key, Body=body, ContentType="text/csv")
    print('Successfully write to the S3 bucket')

    return {
        "status": "ok",
        "datapoints": {
            "timestamps": len(all_ts),
            "cpu": len(cpu_map),
            "network_in": len(in_map),
            "network_out": len(out_map),
        },
        "s3_key": key,
        "period_seconds": PERIOD,
        "window_start": start.isoformat(),
        "window_end": end.isoformat(),
    }


# -----------------------
# Helpers
# -----------------------
def _fmt(val):
    """
    Format numeric values:
      - CPU: keep 3 decimals
      - Network bytes: integer if whole, else 3 decimals
      - None → empty string
    """
    if val is None:
        return ""
    # Avoid scientific notation in CSV; keep it human-friendly
    if float(val).is_integer():
        return str(int(val))
    return f"{float(val):.3f}"


def _to_csv_bytes(rows):
    """
    Convert a list-of-lists into CSV bytes (UTF-8).
    Using csv module to handle proper escaping if needed.
    """
    from io import StringIO

    buf = StringIO()
    writer = csv.writer(buf, lineterminator="\n")
    writer.writerows(rows)
    return buf.getvalue().encode("utf-8")