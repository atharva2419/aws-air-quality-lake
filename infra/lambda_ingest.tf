# -----------------------------------------------------------------------------
# lambda_ingest.tf
#
# The ingestion pipeline: every hour, EventBridge triggers a Lambda function
# that fetches air-quality data and writes it to the raw bucket.
#
#   EventBridge rule (hourly) --> Lambda (src/ingest/handler.py) --> raw bucket
#
# Four pieces are needed:
#   1. A zip of the Python code (Lambda runs code from a zip package)
#   2. An IAM role: the identity the function runs as, and what it may do
#   3. The Lambda function itself, plus a log group for its output
#   4. The EventBridge schedule and permission for it to invoke the function
# -----------------------------------------------------------------------------

# --- 1. Package the code -----------------------------------------------------

# Zips src/ingest/ at plan time. When the code changes, the zip's hash changes,
# and Terraform knows to upload a new version.
data "archive_file" "ingest" {
  type        = "zip"
  source_dir  = "${path.module}/../src/ingest"
  output_path = "${path.module}/build/ingest.zip"
}

# --- 2. IAM role -------------------------------------------------------------

# A role has two halves. The "assume role" (trust) policy says WHO may use the
# role: here, only the Lambda service.
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ingest" {
  name               = "${var.project_name}-ingest-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# The other half says WHAT the role may do. Least privilege: write objects
# under raw/ in the raw bucket, and write its own logs. Nothing else, so it
# cannot read, delete, or touch any other bucket.
data "aws_iam_policy_document" "ingest" {
  statement {
    sid       = "WriteRawObjects"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this["raw"].arn}/raw/*"]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.ingest.arn}:*"]
  }
}

resource "aws_iam_role_policy" "ingest" {
  name   = "ingest"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest.json
}

# --- 3. The function ---------------------------------------------------------

# CloudWatch Logs is where print() output and errors from the function go.
# Lambda would create this group automatically, but then logs are kept forever
# and `terraform destroy` would leave it behind. Managing it here fixes both.
resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/${var.project_name}-ingest"
  retention_in_days = 14
}

resource "aws_lambda_function" "ingest" {
  function_name = "${var.project_name}-ingest"
  description   = "Fetches hourly air quality from Open-Meteo into the raw bucket."
  role          = aws_iam_role.ingest.arn

  filename         = data.archive_file.ingest.output_path
  source_code_hash = data.archive_file.ingest.output_base64sha256

  runtime = "python3.13"
  handler = "handler.lambda_handler" # <file name>.<function name>

  timeout     = 30  # seconds; the default of 3 is tight for an HTTP call
  memory_size = 128 # MB; the minimum, plenty for this job

  environment {
    variables = {
      RAW_BUCKET = aws_s3_bucket.this["raw"].bucket
      CITIES     = jsonencode(var.cities)
    }
  }

  # Make sure the log group and permissions exist before the first run.
  depends_on = [
    aws_cloudwatch_log_group.ingest,
    aws_iam_role_policy.ingest,
  ]
}

# --- 4. The schedule ---------------------------------------------------------

# An EventBridge rule with a schedule is AWS's cron. This fires at 5 minutes
# past every hour (UTC). Format: cron(minute hour day-of-month month day-of-week year)
resource "aws_cloudwatch_event_rule" "ingest_hourly" {
  name                = "${var.project_name}-ingest-hourly"
  description         = "Triggers the ingestion Lambda once an hour."
  schedule_expression = "cron(5 * * * ? *)"
}

# The target is what the rule triggers.
resource "aws_cloudwatch_event_target" "ingest" {
  rule = aws_cloudwatch_event_rule.ingest_hourly.name
  arn  = aws_lambda_function.ingest.arn
}

# Lambda functions reject callers by default. This allows this one rule
# (and only this rule) to invoke the function.
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ingest_hourly.arn
}
