# One-time setup: the S3 bucket that holds Terraform state for both
# environments. Uses local state itself (chicken-and-egg). Locking uses
# S3-native lockfiles (Terraform >= 1.10), so no DynamoDB table is needed.
#
#   cd bootstrap && terraform init && terraform apply

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "state_bucket_name" {
  type    = string
  default = "epixdevo-storm-ready-tfstate"
}

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ── Demo site certificate ──
# Lives here, not in the environment, so it survives `terraform destroy` of
# staging and only has to be DNS-validated once. DNS is at GoDaddy, so the
# validation record is added there by hand (see the output below).

variable "demo_domain" {
  description = "Custom hostname for the staging demo site."
  type        = string
  default     = "demo.epixdevo.org"
}

resource "aws_acm_certificate" "demo" {
  domain_name       = var.demo_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "godaddy_certificate_validation_record" {
  description = "Add this CNAME in GoDaddy DNS so ACM can issue the certificate."
  value = {
    for o in aws_acm_certificate.demo.domain_validation_options : o.domain_name => {
      type = o.resource_record_type
      # GoDaddy wants the host relative to the domain, without the trailing dot.
      host  = trimsuffix(trimsuffix(o.resource_record_name, "."), ".epixdevo.org")
      value = trimsuffix(o.resource_record_value, ".")
    }
  }
}
