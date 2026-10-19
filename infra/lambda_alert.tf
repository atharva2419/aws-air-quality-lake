# -----------------------------------------------------------------------------
# lambda_alert.tf
#
# Alerting: when a new raw file lands, a third Lambda checks each city's AQI
# against var.aqi_alert_threshold and publishes to the SNS topic (which
# emails you) when a city crosses it.
#
#   raw bucket (new .json) --> EventBridge rule --> alert Lambda --> SNS --> email
#
# Why EventBridge and not a direct S3 trigger like the transform uses? S3 can
# only send a given kind of event (here: new .json under raw/) to ONE direct
# destination, and the transform already has it. Turning on S3's EventBridge
# integration publishes every bucket event to EventBridge, where any number
# of rules can each route it somewhere. That is called "fan-out".
# -----------------------------------------------------------------------------

# --- 1. Package the code -----------------------------------------------------

data "archive_file" "alert" {
  type        = "zip"
  source_dir  = "${path.module}/../src/alert"
  output_path = "${path.module}/build/alert.zip"
}

# --- 2. IAM role -------------------------------------------------------------

resource "aws_iam_role" "alert" {
  name               = "${var.project_name}-alert-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json # defined in lambda_ingest.tf
}

# Least privilege: read raw files, publish to the one alerts topic, write logs.
data "aws_iam_policy_document" "alert" {
  # Without list permission, reading a missing file (e.g. the previous hour
  # before ingestion started) returns "Access Denied" instead of "No such key".
  statement {
    sid       = "ListRawObjects"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this["raw"].arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["raw/*"]
    }
  }

  statement {
    sid       = "ReadRawObjects"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this["raw"].arn}/raw/*"]
  }

  statement {
    sid       = "PublishAlerts"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.alert.arn}:*"]
  }
}

resource "aws_iam_role_policy" "alert" {
  name   = "alert"
  role   = aws_iam_role.alert.id
  policy = data.aws_iam_policy_document.alert.json
}

# --- 3. The function ---------------------------------------------------------

resource "aws_cloudwatch_log_group" "alert" {
  name              = "/aws/lambda/${var.project_name}-alert"
  retention_in_days = 14
}

resource "aws_lambda_function" "alert" {
  function_name = "${var.project_name}-alert"
  description   = "Emails via SNS when a city's AQI crosses the alert threshold."
  role          = aws_iam_role.alert.arn

  filename         = data.archive_file.alert.output_path
  source_code_hash = data.archive_file.alert.output_base64sha256

  runtime = "python3.13"
  handler = "handler.lambda_handler"

  timeout     = 30
  memory_size = 128

  environment {
    variables = {
      RAW_BUCKET    = aws_s3_bucket.this["raw"].bucket
      TOPIC_ARN     = aws_sns_topic.alerts.arn
      AQI_THRESHOLD = tostring(var.aqi_alert_threshold)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.alert,
    aws_iam_role_policy.alert,
  ]
}

# --- 4. The trigger ----------------------------------------------------------

# Matches "Object Created" events from the raw bucket for .json keys under
# raw/. (S3 sends these to EventBridge because of `eventbridge = true` on
# aws_s3_bucket_notification.raw in lambda_transform.tf.)
resource "aws_cloudwatch_event_rule" "raw_object_created" {
  name        = "${var.project_name}-raw-object-created"
  description = "New raw air-quality file landed; run the alert check."

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.this["raw"].bucket] }
      object = { key = [{ wildcard = "raw/*.json" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "alert" {
  rule = aws_cloudwatch_event_rule.raw_object_created.name
  arn  = aws_lambda_function.alert.arn
}

resource "aws_lambda_permission" "allow_eventbridge_alert" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.alert.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.raw_object_created.arn
}
