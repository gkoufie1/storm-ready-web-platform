output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_arn_suffix" {
  value = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  value = aws_lb_target_group.cms.arn_suffix
}

output "tasks_security_group_id" {
  value = aws_security_group.tasks.id
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.cms.name
}

output "service_arn" {
  value = aws_ecs_service.cms.id
}

output "scalable_target_resource_id" {
  value = aws_appautoscaling_target.cms.resource_id
}

output "min_tasks" {
  value = var.min_tasks
}

output "max_tasks" {
  value = var.max_tasks
}
