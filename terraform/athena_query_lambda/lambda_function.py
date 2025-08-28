import os
import json
import time
import boto3
from urllib.parse import urlparse

athena = boto3.client("athena")
s3 = boto3.client("s3")

# Config from environment variables
DATABASE = os.getenv("ATHENA_DATABASE", "cpu_metrics")
OUTPUT = os.getenv("ATHENA_OUTPUT_S3", "s3://damao-cpu-metrics/athena-query-results/")
TABLE = os.getenv("ATHENA_TABLE", "ec2_metrics_typed")
MAX_WAIT = int(os.getenv("ATHENA_TIMEOUT", "50"))  # seconds

def lambda_handler(event, context):
    # 1. Parse query or fallback to default
    body = {}
    if "body" in event:
        try:
            body = json.loads(event["body"]) if isinstance(event["body"], str) else event["body"]
        except:
            body = {}
    elif isinstance(event, dict):
        body = event

    query = body.get("query", f"SELECT * FROM {DATABASE}.{TABLE} LIMIT 20;")

    # 2. Start Athena query
    try:
        response = athena.start_query_execution(
            QueryString=query,
            QueryExecutionContext={"Database": DATABASE},
            ResultConfiguration={"OutputLocation": OUTPUT},
        )
        qid = response["QueryExecutionId"]
    except Exception as e:
        return _response(500, {"error": f"Failed to start query: {str(e)}"})

    # 3. Wait for query completion
    start_time = time.time()
    while True:
        status = athena.get_query_execution(QueryExecutionId=qid)
        state = status["QueryExecution"]["Status"]["State"]

        if state in ["SUCCEEDED", "FAILED", "CANCELLED"]:
            break
        if time.time() - start_time > MAX_WAIT:
            return _response(504, {"error": "Athena query timed out"})
        time.sleep(1)

    # 4. Handle query failure
    if state != "SUCCEEDED":
        reason = status["QueryExecution"]["Status"].get("StateChangeReason", "Unknown error")
        return _response(500, {"error": f"Query failed: {reason}"})

    # 5. Get the generated result CSV location
    result_output = status["QueryExecution"]["ResultConfiguration"]["OutputLocation"]
    parsed = urlparse(result_output)
    bucket = parsed.netloc
    key = parsed.path.lstrip("/")

    # 6. Copy result CSV to a fixed key: latest.csv
    fixed_key = "athena-query-results/latest.csv"
    try:
        s3.copy_object(
            Bucket=bucket,
            CopySource={"Bucket": bucket, "Key": key},
            Key=fixed_key
        )
    except Exception as e:
        return _response(500, {"error": f"Failed to copy latest.csv: {str(e)}"})

    # 7. Fetch first 50 rows for API response
    result = athena.get_query_results(QueryExecutionId=qid)
    rows_data = result["ResultSet"]["Rows"]
    headers = [col.get("VarCharValue", "") for col in rows_data[0]["Data"]]
    rows = [
        {headers[i]: col.get("VarCharValue", None) for i, col in enumerate(row["Data"])}
        for row in rows_data[1:]
    ]

    # 8. Return JSON + fixed S3 link
    return _response(200, {
        "data": rows,
        "csv_url": f"s3://{bucket}/{fixed_key}"
    })


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body)
    }
