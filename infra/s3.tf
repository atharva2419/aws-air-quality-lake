# -----------------------------------------------------------------------------
# s3.tf
#
# The storage layer of the data lake. S3 is object storage: "buckets" hold
# "objects" (files). We use three buckets:
#
#   raw            - data exactly as ingested from the source API (raw/ zone)
#   curated        - cleaned, partitioned data ready to query (curated/ zone)
#   athena_results - where Athena writes query output files (scratch space)
#
# Bucket names are global across ALL AWS accounts, so we append the account
# ID, e.g. "aqlake-raw-123456789012".
#
# Note: in AWS provider v5, bucket settings (encryption, public access,
# lifecycle) are separate resources that attach to a bucket, not nested blocks.
# -----------------------------------------------------------------------------

locals {
  account_id = data.aws_caller_identity.current.account_id

  # One map entry per bucket. for_each below creates one bucket per entry,
  # so the shared settings are written once and applied to all three.
  buckets = {
    raw            = "${var.project_name}-raw-${local.account_id}"
    curated        = "${var.project_name}-curated-${local.account_id}"
    athena_results = "${var.project_name}-athena-results-${local.account_id}"
  }
}

# The buckets themselves.
resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket = each.value

  # Lets `terraform destroy` delete the bucket even if it still contains
  # objects. Convenient for a learning project; dangerous for real data.
  force_destroy = true

  tags = {
    Zone = each.key
  }
}

# Block every form of public access (public ACLs and public bucket policies).
# This is the single most important S3 safety setting.
resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Server-side encryption with S3-managed keys (SSE-S3, algorithm AES256).
# Free, and every object is encrypted at rest automatically.
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Lifecycle: raw data is rarely re-read after the first month, so move it to
# Standard-Infrequent Access (cheaper storage, small per-GB retrieval fee).
# Standard-IA bills a 128 KB minimum per object, and S3 skips transitioning
# objects under 128 KB by default, so this pays off for batched files rather
# than many tiny JSON files.
resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.this["raw"].id

  rule {
    id     = "raw-to-standard-ia"
    status = "Enabled"

    filter {} # empty filter = apply to every object in the bucket

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
  }
}

# Lifecycle: Athena query results are throwaway; delete them after 7 days.
resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.this["athena_results"].id

  rule {
    id     = "expire-query-results"
    status = "Enabled"

    filter {}

    expiration {
      days = 7
    }

    # Also clean up partial uploads left behind by failed queries.
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
