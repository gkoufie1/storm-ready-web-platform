variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "public_subnet_ids" {
  description = "Subnets for the ALB."
  type        = list(string)
}

variable "app_subnet_ids" {
  description = "Subnets for the Fargate tasks."
  type        = list(string)
}

variable "data_subnet_ids" {
  description = "Subnets for EFS mount targets."
  type        = list(string)
}

variable "assign_public_ip" {
  description = "Give tasks a public IP (needed when there's no NAT gateway)."
  type        = bool
}

variable "site_domain" {
  description = "Public hostname WordPress should generate URLs for (the CloudFront domain or a custom alias)."
  type        = string
}

variable "origin_verify_secret" {
  description = "Shared secret CloudFront sends as X-Origin-Verify; the ALB rejects requests without it."
  type        = string
  sensitive   = true
}

variable "container_image" {
  description = "WordPress image. Pin a specific tag; mirror into ECR for production."
  type        = string
  default     = "wordpress:6.6-php8.2-apache"
}

variable "task_cpu" {
  type    = number
  default = 512
}

variable "task_memory" {
  type    = number
  default = 1024
}

variable "min_tasks" {
  description = "Baseline minimum running tasks."
  type        = number
  default     = 1
}

variable "max_tasks" {
  description = "Baseline maximum running tasks."
  type        = number
  default     = 4
}

variable "target_requests_per_task" {
  description = "Scale out when origin requests per task per minute exceed this."
  type        = number
  default     = 300
}

variable "db_endpoint" {
  type = string
}

variable "db_name" {
  type = string
}

variable "db_username" {
  type = string
}

variable "db_secret_arn" {
  description = "RDS-managed master user secret (JSON with a password key)."
  type        = string
}

variable "container_insights" {
  type    = bool
  default = false
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "log_retention_days" {
  type    = number
  default = 30
}
