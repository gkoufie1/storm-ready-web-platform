# Production: private app subnets behind a NAT gateway, an Aurora writer
# plus a reader in a second AZ, two tasks minimum, deletion protection on.
module "platform" {
  source = "../../modules/platform"

  environment         = "prod"
  vpc_cidr            = "10.50.0.0/16"
  availability_zones  = ["us-east-1a", "us-east-1b"]
  enable_nat_gateway  = true
  db_instance_count   = 2
  deletion_protection = true

  baseline = {
    min_tasks = 2
    max_tasks = 8
    min_acu   = 0.5
    max_acu   = 8
    ttl       = { min = 0, default = 120, max = 86400 }
  }

  emergency = {
    min_tasks = 6
    max_tasks = 30
    min_acu   = 4
    max_acu   = 16
    ttl       = { min = 300, default = 900, max = 86400 }
  }

  admin_allowed_cidrs     = var.admin_allowed_cidrs
  rate_limit_exempt_cidrs = var.rate_limit_exempt_cidrs
  alert_email             = var.alert_email

  aliases             = var.custom_domain == "" ? [] : [var.custom_domain]
  acm_certificate_arn = var.custom_domain == "" ? null : data.aws_acm_certificate.site[0].arn

  auto_trigger_requests_per_minute = 20000
}

# The certificate is created (and validated once) in bootstrap/.
data "aws_acm_certificate" "site" {
  count       = var.custom_domain == "" ? 0 : 1
  domain      = var.custom_domain
  statuses    = ["ISSUED"]
  most_recent = true
}
