locals {
  alb_origin_id      = "cms-alb"
  failover_origin_id = "static-failover"
  origin_group_id    = "cms-with-static-failover"

  # Paths that need POST, cookies, or must never be cached. They go straight
  # to the CMS — origin groups only support GET/HEAD/OPTIONS.
  dynamic_paths = [
    "/wp-admin/*",
    "/wp-login.php",
    "/wp-json/*",
    "/wp-comments-post.php",
    "/wp-cron.php",
  ]
}

# ── Static failover bucket: a crawled snapshot of the public site ──

resource "aws_s3_bucket" "failover" {
  bucket_prefix = "${var.name}-failover-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "failover" {
  bucket                  = aws_s3_bucket.failover.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "failover" {
  bucket = aws_s3_bucket.failover.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "failover" {
  bucket = aws_s3_bucket.failover.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "failover" {
  bucket = aws_s3_bucket.failover.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Each snapshot overwrites the last; keep a week of history to roll back to.
resource "aws_s3_bucket_lifecycle_configuration" "failover" {
  bucket = aws_s3_bucket.failover.id

  rule {
    id     = "expire-old-snapshots"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_cloudfront_origin_access_control" "failover" {
  name                              = "${var.name}-failover"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_iam_policy_document" "failover_bucket" {
  statement {
    sid       = "CloudFrontReadOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.failover.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.failover.arn,
      "${aws_s3_bucket.failover.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "failover" {
  bucket = aws_s3_bucket.failover.id
  policy = data.aws_iam_policy_document.failover_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.failover]
}

# ── Cache & request policies ──

# The public-site cache policy. Emergency Mode rewrites its TTLs at runtime
# (min TTL > 0 forces caching even when WordPress says no-cache).
resource "aws_cloudfront_cache_policy" "public" {
  name        = "${var.name}-public"
  comment     = "Public pages. TTLs are managed by the Emergency Mode Lambda."
  min_ttl     = var.normal_ttl.min
  default_ttl = var.normal_ttl.default
  max_ttl     = var.normal_ttl.max

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    # Logged-in cookies are deliberately NOT part of the key: the public
    # site is the same for everyone, and editors work under /wp-admin.
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "all"
    }
  }

  lifecycle {
    ignore_changes = [min_ttl, default_ttl, max_ttl]
  }
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

data "aws_cloudfront_response_headers_policy" "security" {
  name = "Managed-SecurityHeadersPolicy"
}

# ── Distribution ──

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  is_ipv6_enabled = true
  http_version    = "http2and3"
  comment         = "${var.name} public site"
  price_class     = var.price_class
  aliases         = var.aliases
  web_acl_id      = aws_wafv2_web_acl.this.arn

  origin {
    origin_id   = local.alb_origin_id
    domain_name = var.alb_dns_name

    # Fail fast so the origin group falls back to S3 quickly.
    connection_attempts = 1
    connection_timeout  = 3

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 15
      origin_keepalive_timeout = 5
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = var.origin_verify_secret
    }
  }

  # Each crawled page is stored under a key ending in "/" (e.g. site/about/),
  # so with origin_path "/site" a request for /about/ maps directly to it —
  # no edge function needed to append index.html.
  origin {
    origin_id                = local.failover_origin_id
    domain_name              = aws_s3_bucket.failover.bucket_regional_domain_name
    origin_path              = "/site"
    origin_access_control_id = aws_cloudfront_origin_access_control.failover.id
  }

  origin_group {
    origin_id = local.origin_group_id

    failover_criteria {
      status_codes = [500, 502, 503, 504]
    }

    member {
      origin_id = local.alb_origin_id
    }
    member {
      origin_id = local.failover_origin_id
    }
  }

  default_cache_behavior {
    target_origin_id           = local.origin_group_id
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = aws_cloudfront_cache_policy.public.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
  }

  dynamic "ordered_cache_behavior" {
    for_each = local.dynamic_paths
    content {
      path_pattern               = ordered_cache_behavior.value
      target_origin_id           = local.alb_origin_id
      viewer_protocol_policy     = "redirect-to-https"
      allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods             = ["GET", "HEAD"]
      compress                   = true
      cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
      origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
      response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.acm_certificate_arn == null
    acm_certificate_arn            = var.acm_certificate_arn
    ssl_support_method             = var.acm_certificate_arn == null ? null : "sni-only"
    minimum_protocol_version       = var.acm_certificate_arn == null ? "TLSv1" : "TLSv1.2_2021"
  }
}
