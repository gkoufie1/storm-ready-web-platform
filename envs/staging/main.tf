# Staging: cheapest shape that still behaves like prod. No NAT gateway
# (tasks run in public subnets behind the ALB-only security group), one
# Aurora writer that auto-pauses when idle, a single task at rest.
module "platform" {
  source = "../../modules/platform"

  environment        = "staging"
  vpc_cidr           = "10.40.0.0/16"
  availability_zones = ["us-east-1a", "us-east-1b"]
  enable_nat_gateway = false
  db_instance_count  = 1

  baseline = {
    min_tasks = 1
    max_tasks = 4
    min_acu   = 0
    max_acu   = 4
    ttl       = { min = 0, default = 60, max = 86400 }
  }

  emergency = {
    min_tasks = 3
    max_tasks = 12
    min_acu   = 1
    max_acu   = 8
    ttl       = { min = 300, default = 600, max = 86400 }
  }

  admin_allowed_cidrs     = var.admin_allowed_cidrs
  rate_limit_exempt_cidrs = var.rate_limit_exempt_cidrs
  loadtest_token          = var.loadtest_token
  alert_email             = var.alert_email

  aliases             = var.custom_domain == "" ? [] : [var.custom_domain]
  acm_certificate_arn = var.custom_domain == "" ? null : data.aws_acm_certificate.site[0].arn

  # Staging demonstrates the auto-trigger at a level a k6 run can reach.
  auto_trigger_requests_per_minute = 3000
}

# The certificate is created (and validated once) in bootstrap/.
data "aws_acm_certificate" "site" {
  count       = var.custom_domain == "" ? 0 : 1
  domain      = var.custom_domain
  statuses    = ["ISSUED"]
  most_recent = true
}
