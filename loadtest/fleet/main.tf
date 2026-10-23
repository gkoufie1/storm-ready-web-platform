# Short-lived k6 fleet for proving SOW 3.3 (~1M requests/minute).
#
# Load generators are spread across three regions so traffic enters many
# CloudFront edge locations, as real statewide traffic would — a single
# location would only ever exercise one edge.
#
# Ephemeral by design: local state, apply right before a test, destroy right
# after. No inbound access; commands arrive over SSM. See README.md.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  tags = {
    Project   = "storm-ready-loadtest"
    ManagedBy = "terraform"
    Owner     = "EpixDevo"
  }
}

provider "aws" {
  alias  = "use1"
  region = "us-east-1"
  default_tags { tags = local.tags }
}

provider "aws" {
  alias  = "use2"
  region = "us-east-2"
  default_tags { tags = local.tags }
}

provider "aws" {
  alias  = "usw2"
  region = "us-west-2"
  default_tags { tags = local.tags }
}

# ── Results bucket: each generator uploads its k6 summary here ──

resource "aws_s3_bucket" "results" {
  provider      = aws.use1
  bucket_prefix = "storm-ready-loadtest-results-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "results" {
  provider                = aws.use1
  bucket                  = aws_s3_bucket.results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  provider = aws.use1
  bucket   = aws_s3_bucket.results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ── Instance role (IAM is global; one role serves every region) ──

data "aws_iam_policy_document" "assume" {
  provider = aws.use1
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "generator" {
  provider           = aws.use1
  name_prefix        = "storm-ready-loadtest-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  provider   = aws.use1
  role       = aws_iam_role.generator.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "results" {
  provider = aws.use1
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.results.arn}/*"]
  }
}

resource "aws_iam_role_policy" "results" {
  provider = aws.use1
  name     = "upload-results"
  role     = aws_iam_role.generator.id
  policy   = data.aws_iam_policy_document.results.json
}

resource "aws_iam_instance_profile" "generator" {
  provider    = aws.use1
  name_prefix = "storm-ready-loadtest-"
  role        = aws_iam_role.generator.name
}

# ── Generators per region ──

locals {
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    k6_version = var.k6_version
    script_b64 = base64encode(file("${path.module}/arrival.js"))
  })
}

module "use1" {
  source    = "./region"
  providers = { aws = aws.use1 }

  cidr                  = "10.90.0.0/24"
  instance_count        = var.instances_per_region
  instance_type         = var.instance_type
  instance_profile_name = aws_iam_instance_profile.generator.name
  user_data             = local.user_data
}

module "use2" {
  source    = "./region"
  providers = { aws = aws.use2 }

  cidr                  = "10.91.0.0/24"
  instance_count        = var.instances_per_region
  instance_type         = var.instance_type
  instance_profile_name = aws_iam_instance_profile.generator.name
  user_data             = local.user_data
}

module "usw2" {
  source    = "./region"
  providers = { aws = aws.usw2 }

  cidr                  = "10.92.0.0/24"
  instance_count        = var.instances_per_region
  instance_type         = var.instance_type
  instance_profile_name = aws_iam_instance_profile.generator.name
  user_data             = local.user_data
}
