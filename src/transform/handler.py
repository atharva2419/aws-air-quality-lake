"""Transform Lambda: turn raw hourly JSON into one clean Parquet file per day.

Triggered by S3 whenever the ingestion Lambda writes a new raw file (see
infra/lambda_transform.tf). For each day that received a new file, it reads
ALL of that day's raw files and rewrites the day's Parquet file from scratch:

    s3://<raw bucket>/raw/2026/10/13/*.json
        --> s3://<curated bucket>/curated/air_quality/date=2026-10-13/data.parquet

Rebuilding the whole day each time (instead of appending) keeps this simple
and safe to re-run: the output only ever depends on what is in raw/.

The result has one row per city per hour and one column per measurement.
The "date=..." folder name is a partition: query engines like Athena treat it
as a column and skip folders that a query's WHERE clause rules out.

It can also be run by hand. Invoking it with no payload rebuilds every day
found in raw/; {"date": "2026-10-13"} rebuilds just that day.

pyarrow (the library that writes Parquet) is not in the standard Lambda
runtime; it comes from the AWS-managed "AWS SDK for pandas" layer.
"""

import json
import os

import re
import urllib.parse
from datetime import datetime, timezone
from io import BytesIO

import boto3
import pyarrow as pa
import pyarrow.parquet as pq

RAW_BUCKET = os.environ["RAW_BUCKET"]
CURATED_BUCKET = os.environ["CURATED_BUCKET"]

RAW_PREFIX = "raw/"
CURATED_PREFIX = "curated/air_quality/"

# Matches raw keys written by the ingestion Lambda: raw/YYYY/MM/DD/HH.json
RAW_KEY_PATTERN = re.compile(r"^raw/(\d{4})/(\d{2})/(\d{2})/\d{2}\.json$")

# Measurement columns, copied straight from the API's "current" block.
POLLUTANTS = ["pm2_5", "pm10", "nitrogen_dioxide", "ozone", "sulphur_dioxide", "carbon_monoxide"]

# An explicit schema keeps column types stable from file to file, even if a
# value is missing (null) or the API returns 12 instead of 12.0.
SCHEMA = pa.schema(
    [
        ("city", pa.string()),
        # Grid point the model data is for (the API snaps to its nearest cell).
        ("latitude", pa.float64()),
        ("longitude", pa.float64()),
        ("observed_at", pa.timestamp("ms", tz="UTC")),
        ("us_aqi", pa.int32()),
        *[(name, pa.float64()) for name in POLLUTANTS],  # µg/m³
        ("ingested_at", pa.timestamp("ms", tz="UTC")),
    ]
)

s3 = boto3.client("s3")


def list_keys(prefix):
    """All object keys in the raw bucket under a prefix (S3 lists 1000 per page)."""
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=RAW_BUCKET, Prefix=prefix):
        for obj in page.get("Contents", []):
            yield obj["Key"]


def date_of(key):
    """'raw/2026/10/13/22.json' -> '2026-10-13'; None if the key isn't a raw file."""
    match = RAW_KEY_PATTERN.match(key)
    return "-".join(match.groups()) if match else None


def dates_to_rebuild(event):
    """Work out which days this invocation should rebuild."""
    if "Records" in event:  # S3 notification: the days of the files that just arrived
        keys = [urllib.parse.unquote_plus(r["s3"]["object"]["key"]) for r in event["Records"]]
    elif "date" in event:  # manual: one specific day
        return {event["date"]}
    else:  # manual, no payload: every day present in raw/
        keys = list_keys(RAW_PREFIX)
    return {d for d in map(date_of, keys) if d}


def parse_utc(text):
    """Parse an ISO timestamp; the API's times have no offset but are GMT."""
    parsed = datetime.fromisoformat(text)
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def rows_from_raw_file(key):
    """Flatten one raw file (10 cities) into one dict per city."""
    body = s3.get_object(Bucket=RAW_BUCKET, Key=key)["Body"].read()
    payload = json.loads(body)
    ingested_at = parse_utc(payload["ingested_at"])

    for location in payload["locations"]:
        data = location["data"]
        current = data["current"]
        yield {
            "city": location["city"],
            "latitude": data["latitude"],
            "longitude": data["longitude"],
            "observed_at": parse_utc(current["time"]),
            "us_aqi": current.get("us_aqi"),
            **{name: current.get(name) for name in POLLUTANTS},
            "ingested_at": ingested_at,
        }


def rebuild_date(date):
    """Rewrite one day's Parquet file from all of that day's raw files."""
    year, month, day = date.split("-")
    keys = [k for k in list_keys(f"{RAW_PREFIX}{year}/{month}/{day}/") if date_of(k)]

    rows = [row for key in keys for row in rows_from_raw_file(key)]
    if not rows:
        print(f"{date}: no raw data, nothing written")
        return None
    rows.sort(key=lambda r: (r["observed_at"], r["city"]))

    buffer = BytesIO()
    pq.write_table(pa.Table.from_pylist(rows, schema=SCHEMA), buffer, compression="snappy")

    out_key = f"{CURATED_PREFIX}date={date}/data.parquet"
    s3.put_object(Bucket=CURATED_BUCKET, Key=out_key, Body=buffer.getvalue())
    print(f"{date}: {len(keys)} raw files -> {len(rows)} rows -> s3://{CURATED_BUCKET}/{out_key}")
    return {"date": date, "raw_files": len(keys), "rows": len(rows), "key": out_key}


def lambda_handler(event, context):
    results = [rebuild_date(date) for date in sorted(dates_to_rebuild(event or {}))]
    return {"rebuilt": [r for r in results if r]}
