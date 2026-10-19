# -----------------------------------------------------------------------------
# providers.tf
#
# Tells Terraform which version of itself and which provider plugins to use.
# A "provider" is the plugin that knows how to talk to a cloud API (here: AWS).
#
# State: with no `backend` block, Terraform keeps state in a local file
# (terraform.tfstate) next to these files. That's fine while learning; later you
# can move it to an S3 backend so it's shared and not lost with your laptop.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0" # any 5.x release, never 6.0 (avoids breaking changes)
    }
    # Small helper provider that builds zip files locally (used to package
    # the Lambda code in lambda_ingest.tf). It does not talk to AWS.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # default_tags are merged into the tags of EVERY taggable resource this
  # provider creates, so you never forget them. Handy for cost reports and for
  # finding everything this project owns in the AWS console.
  default_tags {
    tags = {
      Project   = "air-quality-lake"
      ManagedBy = "terraform"
    }
  }
}

# Looks up the account ID of whatever credentials you're running with.
# Used in s3.tf to make bucket names globally unique.
data "aws_caller_identity" "current" {}
