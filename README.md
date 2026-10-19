# Air Quality Data Lake

A small serverless data lake on AWS. Every hour it collects air-quality readings for 10 US cities, stores them in S3, converts them to Parquet, makes them queryable with SQL in Athena, and emails an alert when a city's AQI goes above 100.

Everything is defined in Terraform. There are no servers, VPCs or databases to run, and at this data volume it costs effectively nothing.

## Architecture

```
EventBridge schedule (hourly, :05 UTC)
        │
        ▼
 ingest Lambda ── Open-Meteo Air Quality API
        │
        ▼
 raw bucket   raw/YYYY/MM/DD/HH.json
        │
        ├── S3 trigger ──────────▶ transform Lambda ──▶ curated bucket
        │                                               curated/air_quality/date=YYYY-MM-DD/data.parquet
        │                                                        │
        │                                               Glue table ──▶ Athena (SQL) ──▶ athena-results bucket
        │
        └── EventBridge rule ────▶ alert Lambda ──▶ SNS topic ──▶ email
```

| Component | AWS service | What it does |
|---|---|---|
| Schedule | EventBridge | Triggers ingestion at 5 minutes past every hour (UTC) |
| Ingest | Lambda | One API call for all cities; saves the response unchanged as JSON in the raw bucket |
| Transform | Lambda + AWS SDK for pandas layer | Rebuilds that day's Parquet file from all of the day's raw files |
| Catalog | Glue Data Catalog | Defines the `air_quality` table over the Parquet files, with partition projection on `date` |
| Query | Athena | SQL over the curated data, in the `aqlake` workgroup (1 GB scan limit per query) |
| Alert | EventBridge + Lambda + SNS | Emails when a city's AQI crosses the threshold, in either direction |
| Storage | S3 (3 buckets) | Private, SSE-S3 encrypted. Raw data moves to Standard-IA after 30 days; Athena results are deleted after 7 days |

**Data source:** the [Open-Meteo Air Quality API](https://open-meteo.com/en/docs/air-quality-api), which needs no API key. Values are modelled estimates from the Copernicus CAMS model on a grid of roughly 40 km, not station measurements.

## Repository layout

```
infra/                      Terraform configuration
  providers.tf              AWS and archive providers, default tags, local state
  variables.tf              Region, name prefix, alert email, AQI threshold, city list
  s3.tf                     Raw, curated and athena-results buckets with their security and lifecycle settings
  sns.tf                    Alerts topic and email subscription
  lambda_ingest.tf          Ingest function, IAM role, hourly schedule
  lambda_transform.tf       Transform function, IAM role, S3 trigger, pyarrow layer
  lambda_alert.tf           Alert function, IAM role, EventBridge rule
  glue_athena.tf            Glue database and table, Athena workgroup, saved queries
  outputs.tf                Resource names printed after apply
  terraform.tfvars.example  Template for your own settings
src/
  ingest/handler.py         Fetch from Open-Meteo, write raw JSON
  transform/handler.py      Raw JSON to daily Parquet
  alert/handler.py          Compare with the previous hour, publish to SNS
```

## Prerequisites

- An AWS account and an IAM user with permission to create S3, Lambda, IAM, EventBridge, SNS, Glue and Athena resources
- [AWS CLI v2](https://aws.amazon.com/cli/), configured with `aws configure`. Check it with `aws sts get-caller-identity`.
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.5 or later

No local Python setup is needed to deploy: Terraform zips the code in `src/`, and the Lambda runtime provides `boto3`. To get editor autocomplete, run `pip install boto3 pyarrow`.

## Deploy

```sh
cd infra
cp terraform.tfvars.example terraform.tfvars   # then set alert_email
terraform init
terraform plan
terraform apply
```

After the first apply:

1. **Confirm the email subscription.** AWS sends a confirmation link to `alert_email`. Alerts are not delivered until you click it.
2. **Wait for the first run, or start one now.** Ingestion runs at :05 every hour. To run it immediately:
   ```sh
   aws lambda invoke --function-name aqlake-ingest out.json
   ```

## Check that it's working

```sh
# Raw files, one per hour
aws s3 ls s3://$(terraform output -raw raw_bucket_name)/raw/ --recursive

# Parquet files, one per day
aws s3 ls s3://$(terraform output -raw curated_bucket_name)/curated/ --recursive
```

Each function writes logs to CloudWatch under `/aws/lambda/aqlake-ingest`, `/aws/lambda/aqlake-transform` and `/aws/lambda/aqlake-alert`. They are kept for 14 days.

The transform runs automatically for each new raw file. To rebuild the Parquet for every day in `raw/`, for example after changing the transform code, invoke it with no payload:

```sh
aws lambda invoke --function-name aqlake-transform out.json
```

## Query with Athena

In the AWS Console, open **Athena → Query editor**, then select the **`aqlake` workgroup** (top right) and the **`aqlake` database**. Two saved queries are under **Saved queries**:

- `latest-aqi-by-city`: the most recent reading for each city
- `daily-aqi-summary`: daily average and worst AQI per city for the last 7 days

Example:

```sql
SELECT city,
       round(avg(us_aqi), 1) AS avg_aqi,
       max(us_aqi)           AS worst_aqi
FROM air_quality
WHERE date >= '2026-10-15'
GROUP BY city
ORDER BY avg_aqi DESC;
```

Filter on `date` whenever you can. It is the partition column, so Athena only reads the matching days.

### Table schema: `aqlake.air_quality`

One row per city per hour.

| Column | Type | Notes |
|---|---|---|
| `city` | string | City name from `var.cities` |
| `latitude`, `longitude` | double | Model grid point nearest the city |
| `observed_at` | timestamp | Hour of the reading, UTC |
| `us_aqi` | int | US Air Quality Index |
| `pm2_5`, `pm10` | double | µg/m³ |
| `nitrogen_dioxide`, `ozone`, `sulphur_dioxide`, `carbon_monoxide` | double | µg/m³ |
| `ingested_at` | timestamp | When the data was fetched, UTC |
| `date` | string (partition) | `yyyy-MM-dd`, UTC |

The table's columns in `infra/glue_athena.tf` must match `SCHEMA` in `src/transform/handler.py`. If you change one, change the other.

## Alerts

The alert Lambda compares each new hour with the previous hour, and sends one email per hour listing:

- cities that rose **above** `aqi_alert_threshold` (default 100, the top of the "moderate" band)
- cities that came back **to or below** it

A city that stays above the threshold does not trigger repeated emails.

**Send a test email.** The first raw file has no previous hour, so every city above the test threshold counts as a crossing. Adjust the `key` to a file that exists in your bucket.

```sh
echo '{"key": "raw/2026/10/13/22.json", "threshold": 30}' > test-alert.json
aws lambda invoke --function-name aqlake-alert --payload fileb://test-alert.json out.json
```

In Windows PowerShell, create the file with `Out-File -Encoding ascii` instead of `>`.

## Configuration

All settings are in `infra/terraform.tfvars`. Change a value, then run `terraform apply`.

| Variable | Default | Purpose |
|---|---|---|
| `aws_region` | `us-west-2` | Region for all resources |
| `project_name` | `aqlake` | Prefix for resource names. Bucket names also end in the account ID. |
| `alert_email` | none (required) | Where alerts are sent |
| `aqi_alert_threshold` | `100` | Alert when US AQI goes above this |
| `cities` | 10 US cities | List of `{ name, latitude, longitude }`. All cities go into one API call. |

## Cost

At this volume (10 cities, hourly) all the services involved stay at or near $0 a month: about 720 runs a month of each Lambda, a few MB of S3 storage, and Athena queries that scan KBs. As a safeguard, set up an AWS Budgets alert under **Billing → Budgets**.

## Tear down

```sh
cd infra
terraform destroy
```

The buckets have `force_destroy = true`, so this deletes them **including all collected data**.

## Notes and limitations

- **State is local.** `infra/terraform.tfstate` records what Terraform has built. Keep it, don't edit it, and never commit it (it is git-ignored). Move it to an S3 backend before sharing the project with others.
- **No backfill.** Data starts from the first deployment. Open-Meteo can return about 3 months of history through `past_days`, but nothing here uses that yet.
- **Times are UTC.** That applies to file paths, partitions and timestamps.
- **The pyarrow layer is pinned.** The transform uses AWS's managed `AWSSDKPandas-Python313` layer at version 12 (set in `lambda_transform.tf`).
