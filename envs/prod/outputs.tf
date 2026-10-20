output "site_url" {
  value = module.platform.site_url
}

output "cloudfront_domain" {
  value = module.platform.cloudfront_domain
}

output "distribution_id" {
  value = module.platform.distribution_id
}

output "alb_dns_name" {
  value = module.platform.alb_dns_name
}

output "failover_bucket" {
  value = module.platform.failover_bucket
}

output "ecs_cluster" {
  value = module.platform.ecs_cluster
}

output "ecs_service" {
  value = module.platform.ecs_service
}

output "emergency_function" {
  value = module.platform.emergency_function
}
