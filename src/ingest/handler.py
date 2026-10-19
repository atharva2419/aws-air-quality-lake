"""Ingestion Lambda: fetch current air quality for each city and save it to S3.

Runs once an hour (triggered by EventBridge, see infra/lambda_ingest.tf).
Each run makes ONE request to the Open-Meteo air-quality API covering every
city, then writes the response as a single JSON file to the raw bucket:

    s3://<raw bucket>/raw/YYYY/MM/DD/HH.json      (times are UTC)

The API response is stored as-is so it can be re-processed later; we only wrap
it with the city name (the API identifies locations by coordinates, not name)
and the time we fetched it.

Uses only the Python standard library plus boto3 (the AWS SDK), which is
pre-installed in the Lambda runtime, so there is nothing to package.
"""

import json
import os
import urllib.parse
import urllib.request
from datetime import datetime, timezone

import boto3

API_URL = "https://air-quality-api.open-meteo.com/v1/air-quality"

# Measurements requested for each city. Pollutants are in µg/m³.
VARIABLES = [
    "us_aqi",
    "pm2_5",
    "pm10",
    "nitrogen_dioxide",
    "ozone",
    "sulphur_dioxide",
    "carbon_monoxide",
]

# Configuration comes from environment variables that Terraform sets on the
# function, so the code never hard-codes bucket names or the city list.
RAW_BUCKET = os.environ["RAW_BUCKET"]
CITIES = json.loads(os.environ["CITIES"])  # [{"name", "latitude", "longitude"}, ...]

# Created once per container, outside the handler, so warm invocations reuse it.
s3 = boto3.client("s3")


def fetch_air_quality(cities):
    """Call Open-Meteo once for all cities; returns one result per city, in order."""
    params = urllib.parse.urlencode(
        {
            "latitude": ",".join(str(c["latitude"]) for c in cities),
            "longitude": ",".join(str(c["longitude"]) for c in cities),
            "current": ",".join(VARIABLES),
            "timezone": "GMT",
        }
    )
    with urllib.request.urlopen(f"{API_URL}?{params}", timeout=20) as response:
        results = json.load(response)

    # With a single location the API returns an object instead of a list.
    if isinstance(results, dict):
        results = [results]
    if len(results) != len(cities):
        raise RuntimeError(f"Asked for {len(cities)} cities but got {len(results)} results")
    return results


def lambda_handler(event, context):
    now = datetime.now(timezone.utc)
    results = fetch_air_quality(CITIES)

    payload = {
        "ingested_at": now.isoformat(timespec="seconds"),
        "source": API_URL,
        "locations": [
            {"city": city["name"], "requested": city, "data": data}
            for city, data in zip(CITIES, results)
        ],
    }

    # One file per hour. Re-running within the same hour overwrites the file
    # rather than creating a duplicate, so retries are harmless.
    key = f"raw/{now:%Y/%m/%d/%H}.json"
    s3.put_object(
        Bucket=RAW_BUCKET,
        Key=key,
        Body=json.dumps(payload).encode("utf-8"),
        ContentType="application/json",
    )

    print(f"Wrote {len(results)} cities to s3://{RAW_BUCKET}/{key}")
    return {"bucket": RAW_BUCKET, "key": key, "cities": len(results)}
