"""Alert Lambda: email when a city's AQI rises above the threshold.

Triggered (through EventBridge) every time a new raw file lands in the raw
bucket (see infra/lambda_alert.tf). It compares this hour's file with the
previous hour's, and publishes ONE message to the SNS topic listing:

  - cities that just went ABOVE the threshold  (previous hour was at/below)
  - cities that just came back to or BELOW it  (previous hour was above)

Comparing with the previous hour means a city that stays above 100 all day
produces one email when it crosses, not one every hour.

It reads the raw JSON (not the Parquet), so it needs no extra libraries and
doesn't have to wait for the transform.

Manual test: invoke with {"key": "raw/2026/10/19/22.json", "threshold": 30}
to check a specific file against a different threshold.
"""

import json
import os
from datetime import datetime, timedelta

import boto3

RAW_BUCKET = os.environ["RAW_BUCKET"]
TOPIC_ARN = os.environ["TOPIC_ARN"]
THRESHOLD = int(os.environ["AQI_THRESHOLD"])

s3 = boto3.client("s3")
sns = boto3.client("sns")


def previous_hour_key(key):
    """'raw/2026/10/20/00.json' -> 'raw/2026/10/19/23.json'"""
    hour = datetime.strptime(key, "raw/%Y/%m/%d/%H.json")
    return (hour - timedelta(hours=1)).strftime("raw/%Y/%m/%d/%H.json")


def read_aqi(key):
    """{city: reading} for one raw file, or None if the file doesn't exist."""
    try:
        body = s3.get_object(Bucket=RAW_BUCKET, Key=key)["Body"].read()
    except s3.exceptions.NoSuchKey:
        return None
    readings = {}
    for location in json.loads(body)["locations"]:
        current = location["data"]["current"]
        readings[location["city"]] = current
    return readings


def is_above(reading, threshold):
    aqi = reading.get("us_aqi") if reading else None
    return aqi is not None and aqi > threshold


def format_reading(city, reading):
    return (
        f"  {city}: AQI {reading['us_aqi']} "
        f"(PM2.5 {reading.get('pm2_5')} µg/m³, ozone {reading.get('ozone')} µg/m³)"
    )


def lambda_handler(event, context):
    # EventBridge S3 event: the key is at detail.object.key. Manual test: event["key"].
    key = event["detail"]["object"]["key"] if "detail" in event else event["key"]
    threshold = int(event.get("threshold", THRESHOLD))

    current = read_aqi(key)
    previous = read_aqi(previous_hour_key(key)) or {}  # no previous file: treat all as below

    went_above = [c for c, r in current.items() if is_above(r, threshold) and not is_above(previous.get(c), threshold)]
    recovered = [c for c, r in current.items() if not is_above(r, threshold) and is_above(previous.get(c), threshold)]

    if not went_above and not recovered:
        print(f"{key}: no threshold crossings (threshold {threshold})")
        return {"key": key, "went_above": [], "recovered": []}

    hour = next(iter(current.values()))["time"]
    lines = [f"Air quality update for {hour} UTC (alert threshold: US AQI above {threshold}).", ""]
    if went_above:
        lines.append("Now ABOVE the threshold:")
        lines += [format_reading(c, current[c]) for c in went_above]
        lines.append("")
    if recovered:
        lines.append("Back to or below the threshold:")
        lines += [format_reading(c, current[c]) for c in recovered]
        lines.append("")
    lines.append("US AQI guide: 0-50 good, 51-100 moderate, 101-150 unhealthy for sensitive groups, 151+ unhealthy.")

    if went_above:
        subject = f"AQI alert: {', '.join(went_above)} above {threshold}"
    else:
        subject = f"AQI back to normal: {', '.join(recovered)}"

    sns.publish(
        TopicArn=TOPIC_ARN,
        Subject=subject[:100],  # SNS email subjects are limited to 100 characters
        Message="\n".join(lines),
    )
    print(f"{key}: published alert. above={went_above} recovered={recovered}")
    return {"key": key, "went_above": went_above, "recovered": recovered}
