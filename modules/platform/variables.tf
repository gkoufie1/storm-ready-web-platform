variable "project" {
  type    = string
  default = "storm-ready"
}

variable "environment" {
  type = string
}

variable "region" {
  description = "Must be us-east-1: CloudFront WAF, ACM certs and CloudFront metrics all live there."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  type = string
}

variable "availability_zones" {
  type = list(string)
}

variable "enable_nat_gateway" {
  type    = bool
  default = false
}

variable "container_image" {
  type    = string
  default = "wordpress:7.1.3-php8.4-apache"
}

variable "db_instance_count" {
  type    = number
  default = 1
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "baseline" {
  description = "Normal-day capacity and cache TTLs."
  type = object({
    min_tasks = number
    max_tasks = number
    min_acu   = number
    max_acu   = number
    ttl       = object({ min = number, default = number, max = number })
  })
}

variable "emergency" {
  description = "Capacity and cache TTLs applied by Emergency Mode."
  type = object({
    min_tasks = number
    max_tasks = number
    min_acu   = number
    max_acu   = number
    ttl       = object({ min = number, default = number, max = number })
  })
}

variable "admin_allowed_cidrs" {
  type = list(string)
}

variable "rate_limit_exempt_cidrs" {
  type    = list(string)
  default = []
}

variable "loadtest_token" {
  type      = string
  default   = ""
  sensitive = true
}

variable "aliases" {
  type    = list(string)
  default = []
}

variable "acm_certificate_arn" {
  type    = string
  default = null
}

variable "auto_trigger_requests_per_minute" {
  type    = number
  default = 0
}

variable "alert_email" {
  type    = string
  default = ""
}
