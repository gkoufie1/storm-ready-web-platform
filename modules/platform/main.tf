# One environment of the platform: network → database → CMS → edge →
# Emergency Mode. Staging and prod both call this with different sizing.

locals {
  name = "${var.project}-${var.environment}"

  # WordPress needs its public hostname; with no custom domain that's the
  # CloudFront domain (Terraform resolves this at the resource level — the
  # task definition waits for the distribution, which waits for the ALB).
  site_domain = length(var.aliases) > 0 ? var.aliases[0] : module.edge.domain_name
}

resource "random_password" "origin_verify" {
  length  = 48
  special = false
}

module "network" {
  source = "../network"

  name               = local.name
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  enable_nat_gateway = var.enable_nat_gateway
}

module "database" {
  source = "../database"

  name                  = local.name
  vpc_id                = module.network.vpc_id
  subnet_ids            = module.network.data_subnet_ids
  app_security_group_id = module.cms.tasks_security_group_id
  min_acu               = var.baseline.min_acu
  max_acu               = var.baseline.max_acu
  instance_count        = var.db_instance_count
  deletion_protection   = var.deletion_protection
}

module "cms" {
  source = "../cms"

  name                 = local.name
  region               = var.region
  vpc_id               = module.network.vpc_id
  vpc_cidr             = module.network.vpc_cidr
  public_subnet_ids    = module.network.public_subnet_ids
  app_subnet_ids       = module.network.app_subnet_ids
  data_subnet_ids      = module.network.data_subnet_ids
  assign_public_ip     = module.network.app_tasks_need_public_ip
  site_domain          = local.site_domain
  origin_verify_secret = random_password.origin_verify.result
  container_image      = var.container_image
  min_tasks            = var.baseline.min_tasks
  max_tasks            = var.baseline.max_tasks
  db_endpoint          = module.database.endpoint
  db_name              = module.database.database_name
  db_username          = module.database.master_username
  db_secret_arn        = module.database.master_secret_arn
  deletion_protection  = var.deletion_protection
}

module "edge" {
  source = "../edge"

  name                    = local.name
  alb_dns_name            = module.cms.alb_dns_name
  origin_verify_secret    = random_password.origin_verify.result
  normal_ttl              = var.baseline.ttl
  admin_allowed_cidrs     = var.admin_allowed_cidrs
  rate_limit_exempt_cidrs = var.rate_limit_exempt_cidrs
  aliases                 = var.aliases
  acm_certificate_arn     = var.acm_certificate_arn
}

module "emergency" {
  source = "../emergency"

  name            = local.name
  ecs_resource_id = module.cms.scalable_target_resource_id
  ecs_service_arn = module.cms.service_arn
  db_cluster_id   = module.database.cluster_id
  db_cluster_arn  = module.database.cluster_arn
  cache_policy_id = module.edge.public_cache_policy_id
  distribution_id = module.edge.distribution_id

  baseline = {
    min_tasks          = var.baseline.min_tasks
    max_tasks          = var.baseline.max_tasks
    min_acu            = var.baseline.min_acu
    max_acu            = var.baseline.max_acu
    auto_pause_seconds = module.database.seconds_until_auto_pause
    ttl                = var.baseline.ttl
  }
  emergency = var.emergency

  auto_trigger_requests_per_minute = var.auto_trigger_requests_per_minute
  alert_email                      = var.alert_email
}
