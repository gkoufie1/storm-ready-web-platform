output "site_url" {
  value = "https://${local.site_domain}"
}

output "cloudfront_domain" {
  value = module.edge.domain_name
}

output "distribution_id" {
  value = module.edge.distribution_id
}

output "alb_dns_name" {
  description = "Direct ALB hostname — should return 403 (proves the origin is locked to CloudFront)."
  value       = module.cms.alb_dns_name
}

output "failover_bucket" {
  value = module.edge.failover_bucket
}

output "ecs_cluster" {
  value = module.cms.cluster_name
}

output "ecs_service" {
  value = module.cms.service_name
}

output "emergency_function" {
  value = module.emergency.function_name
}

output "load_balancer_metric_dimensions" {
  value = {
    LoadBalancer = module.cms.alb_arn_suffix
    TargetGroup  = module.cms.target_group_arn_suffix
  }
}
