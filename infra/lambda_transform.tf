# -----------------------------------------------------------------------------
# lambda_transform.tf
#
# The transform step: whenever a new raw JSON file lands, a second Lambda
# rewrites that day's data as a clean Parquet file in the curated bucket.
#
#   raw bucket (new .json) --S3 event--> Lambda (src/transform/handler.py)
#                                            --> curated bucket (.parquet)
#
# Parquet is a columnar file format: compact, typed, and query engines can read
# only the columns a query needs. It is the standard format for data lakes.
#
# Same four pieces as the ingestion Lambda, with two differences:
#   - the trigger is an S3 event, not a timer
#   - the code needs a library (pyarrow) supplied by a Lambda layer
# -----------------------------------------------------------------------------

locals {
  # A layer is a zip of libraries that Lambda mounts alongside your code. AWS
  # publishes this one ("AWS SDK for pandas"), which includes pyarrow, in every
  # region, so there is nothing to build or upload. The trailing number is the
  # layer version; it is pinned so deployments are repeatable.
  # Account 336392948345 is AWS's own publishing account for this layer.
  pandas_layer_arn = "arn:aws:lambda:${var.aws_region}:336392948345:layer:AWSSDKPandas-Python313:12"
}

# --- 1. Package the code -----------------------------------------------------

data "archive_file" "transform" {
  type        = "zip"
  source_dir  = "${path.module}/../src/transform"
  output_path = "${path.module}/build/transform.zip"
}

# --- 2. IAM role -------------------------------------------------------------

resource "aws_iam_role" "transform" {
  name               = "${var.project_name}-transform-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json # defined in lambda_ingest.tf
}

# Least privilege: read raw, write curated, write its own logs.
data "aws_iam_policy_document" "transform" {
  # Listing is a permission on the bucket itself (not on objects), so it is
  # scoped with a condition instead of a path in the resource.
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
    sid       = "WriteCuratedObjects"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this["curated"].arn}/curated/*"]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.transform.arn}:*"]
  }
}

resource "aws_iam_role_policy" "transform" {
  name   = "transform"
  role   = aws_iam_role.transform.id
  policy = data.aws_iam_policy_document.transform.json
}

# --- 3. The function ---------------------------------------------------------

resource "aws_cloudwatch_log_group" "transform" {
  name              = "/aws/lambda/${var.project_name}-transform"
  retention_in_days = 14
}

resource "aws_lambda_function" "transform" {
  function_name = "${var.project_name}-transform"
  description   = "Rewrites each day's raw JSON as Parquet in the curated bucket."
  role          = aws_iam_role.transform.arn

  filename         = data.archive_file.transform.output_path
  source_code_hash = data.archive_file.transform.output_base64sha256

  runtime = "python3.13"
  handler = "handler.lambda_handler"
  layers  = [local.pandas_layer_arn]

  timeout     = 60  # seconds
  memory_size = 512 # MB; pyarrow is a large library and needs more than the minimum

  environment {
    variables = {
      RAW_BUCKET     = aws_s3_bucket.this["raw"].bucket
      CURATED_BUCKET = aws_s3_bucket.this["curated"].bucket
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.transform,
    aws_iam_role_policy.transform,
  ]
}

# --- 4. The trigger ----------------------------------------------------------

# Allow the raw bucket (and only it, in this account) to invoke the function.
resource "aws_lambda_permission" "allow_raw_bucket" {
  statement_id   = "AllowRawBucketInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.transform.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.this["raw"].arn
  source_account = local.account_id
}

# Tell the raw bucket to send an event to the function every time a .json
# object is created under raw/. This is what chains the two Lambdas together:
# ingestion writes a file, S3 announces it, the transform runs.
resource "aws_s3_bucket_notification" "raw" {
  bucket = aws_s3_bucket.this["raw"].id

  lambda_function {
    lambda_function_arn = aws_lambda_function.transform.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "raw/"
    filter_suffix       = ".json"
  }

  # S3 checks it is allowed to invoke the function when this is created.
  depends_on = [aws_lambda_permission.allow_raw_bucket]
}
