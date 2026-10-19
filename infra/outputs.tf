# -----------------------------------------------------------------------------
# outputs.tf
#
# Outputs are printed after `terraform apply` and can be read any time with
# `terraform output`. Useful for feeding names into scripts or other configs.
# -----------------------------------------------------------------------------

output "raw_bucket_name" {
  description = "S3 bucket for raw ingested data."
  value       = aws_s3_bucket.this["raw"].bucket
}

output "curated_bucket_name" {
  description = "S3 bucket for cleaned, query-ready data."
  value       = aws_s3_bucket.this["curated"].bucket
}

output "athena_results_bucket_name" {
  description = "S3 bucket for Athena query results."
  value       = aws_s3_bucket.this["athena_results"].bucket
}

output "sns_topic_arn" {
  description = "ARN of the alerts SNS topic."
  value       = aws_sns_topic.alerts.arn
}

output "ingest_function_name" {
  description = "Name of the ingestion Lambda function."
  value       = aws_lambda_function.ingest.function_name
}

output "transform_function_name" {
  description = "Name of the transform Lambda function."
  value       = aws_lambda_function.transform.function_name
}

output "glue_database_name" {
  description = "Glue database holding the lake's tables."
  value       = aws_glue_catalog_database.lake.name
}

output "athena_workgroup_name" {
  description = "Athena workgroup to select in the query editor."
  value       = aws_athena_workgroup.lake.name
}
