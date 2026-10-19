# -----------------------------------------------------------------------------
# glue_athena.tf
#
# Makes the curated Parquet files queryable with SQL.
#
#   Glue Data Catalog - stores table DEFINITIONS only (name, columns, types,
#                       where the files live, file format). No data.
#   Athena            - serverless SQL engine. Looks the table up in Glue,
#                       reads the Parquet files straight from S3, and writes
#                       results to the athena-results bucket.
#
# We declare the table here instead of running a Glue crawler: we already know
# the exact schema, so this is free, predictable, and lives in code.
#
# The columns below MUST match SCHEMA in src/transform/handler.py.
# -----------------------------------------------------------------------------

locals {
  curated_table_location = "s3://${aws_s3_bucket.this["curated"].bucket}/curated/air_quality/"
}

# A Glue database is just a namespace (folder) for tables. Glue/Athena names
# may only use lowercase letters, numbers and underscores.
resource "aws_glue_catalog_database" "lake" {
  name        = replace(var.project_name, "-", "_")
  description = "Air-quality data lake tables."
}

resource "aws_glue_catalog_table" "air_quality" {
  name          = "air_quality"
  database_name = aws_glue_catalog_database.lake.name
  description   = "Hourly air quality per city, one row per city per hour. Partitioned by UTC date."
  table_type    = "EXTERNAL_TABLE" # the data lives in S3, outside the catalog

  # One partition column. Its value comes from the folder name
  # (date=2026-10-13), not from inside the Parquet files.
  partition_keys {
    name    = "date"
    type    = "string"
    comment = "UTC date, yyyy-MM-dd. Filter on it to limit how much data a query scans."
  }

  parameters = {
    classification = "parquet"

    # Partition projection: instead of registering every new date=... folder
    # in Glue, we describe the pattern and Athena computes the folder paths
    # from the query's WHERE clause. New days are queryable immediately.
    "projection.enabled"            = "true"
    "projection.date.type"          = "date"
    "projection.date.format"        = "yyyy-MM-dd"
    "projection.date.range"         = "2026-10-13,NOW" # first day of data, through today
    "projection.date.interval"      = "1"
    "projection.date.interval.unit" = "DAYS"
    "storage.location.template"     = "${local.curated_table_location}date=$${date}"
  }

  storage_descriptor {
    location = local.curated_table_location

    # These three class names are how Hive-style catalogs say "Parquet".
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "city"
      type = "string"
    }
    columns {
      name    = "latitude"
      type    = "double"
      comment = "Model grid point latitude (nearest cell to the city)"
    }
    columns {
      name    = "longitude"
      type    = "double"
      comment = "Model grid point longitude"
    }
    columns {
      name    = "observed_at"
      type    = "timestamp"
      comment = "Hour the measurement is for, UTC"
    }
    columns {
      name    = "us_aqi"
      type    = "int"
      comment = "US Air Quality Index"
    }
    columns {
      name    = "pm2_5"
      type    = "double"
      comment = "µg/m³"
    }
    columns {
      name    = "pm10"
      type    = "double"
      comment = "µg/m³"
    }
    columns {
      name    = "nitrogen_dioxide"
      type    = "double"
      comment = "µg/m³"
    }
    columns {
      name    = "ozone"
      type    = "double"
      comment = "µg/m³"
    }
    columns {
      name    = "sulphur_dioxide"
      type    = "double"
      comment = "µg/m³"
    }
    columns {
      name    = "carbon_monoxide"
      type    = "double"
      comment = "µg/m³"
    }
    columns {
      name    = "ingested_at"
      type    = "timestamp"
      comment = "When the ingestion Lambda fetched the data, UTC"
    }
  }
}

# A workgroup holds Athena settings. Pick it in the Athena console (top right
# of the query editor) so queries use these settings.
resource "aws_athena_workgroup" "lake" {
  name          = var.project_name
  description   = "Queries for the air-quality data lake."
  force_destroy = true # lets terraform destroy remove it even with saved query history

  configuration {
    # Users of this workgroup can't override these settings per query.
    enforce_workgroup_configuration = true

    # Cost safety net: cancel any query that would scan more than 1 GB
    # (about half a cent). Our data is KBs per day, so real queries never hit it.
    bytes_scanned_cutoff_per_query = 1073741824

    result_configuration {
      output_location = "s3://${aws_s3_bucket.this["athena_results"].bucket}/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

# Saved example queries; they appear under "Saved queries" in the Athena
# console when the aqlake workgroup is selected.
resource "aws_athena_named_query" "latest_by_city" {
  name        = "latest-aqi-by-city"
  description = "Most recent reading for each city."
  workgroup   = aws_athena_workgroup.lake.name
  database    = aws_glue_catalog_database.lake.name
  query       = <<-SQL
    SELECT city, observed_at, us_aqi, pm2_5, ozone
    FROM air_quality
    WHERE date = cast(current_date AS varchar)
      AND observed_at = (SELECT max(observed_at) FROM air_quality WHERE date = cast(current_date AS varchar))
    ORDER BY us_aqi DESC;
  SQL
}

resource "aws_athena_named_query" "daily_summary" {
  name        = "daily-aqi-summary"
  description = "Daily average and worst AQI per city for the last 7 days."
  workgroup   = aws_athena_workgroup.lake.name
  database    = aws_glue_catalog_database.lake.name
  query       = <<-SQL
    SELECT date, city,
           round(avg(us_aqi), 1) AS avg_aqi,
           max(us_aqi)           AS worst_aqi,
           count(*)              AS hours
    FROM air_quality
    WHERE date >= cast(current_date - interval '7' day AS varchar)
    GROUP BY date, city
    ORDER BY date DESC, worst_aqi DESC;
  SQL
}
