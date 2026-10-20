output "distribution_id" {
  value = aws_cloudfront_distribution.this.id
}

output "distribution_arn" {
  value = aws_cloudfront_distribution.this.arn
}

output "domain_name" {
  value = aws_cloudfront_distribution.this.domain_name
}

output "public_cache_policy_id" {
  value = aws_cloudfront_cache_policy.public.id
}

output "normal_ttl" {
  value = var.normal_ttl
}

output "failover_bucket" {
  value = aws_s3_bucket.failover.bucket
}

output "failover_bucket_arn" {
  value = aws_s3_bucket.failover.arn
}

output "web_acl_name" {
  value = aws_wafv2_web_acl.this.name
}
