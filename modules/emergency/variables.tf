variable "name" {
  type = string
}

variable "ecs_resource_id" {
  description = "Application Auto Scaling resource id: service/<cluster>/<service>."
  type        = string
}

variable "ecs_service_arn" {
  type = string
}

variable "db_cluster_id" {
  type = string
}

variable "db_cluster_arn" {
  type = string
}

variable "cache_policy_id" {
  type = string
}

variable "distribution_id" {
  type = string
}

variable "baseline" {
  description = "Normal-day capacity. 'off' restores exactly this."
  type = object({
    min_tasks          = number
    max_tasks          = number
    min_acu            = number
    max_acu            = number
    auto_pause_seconds = number
    ttl                = object({ min = number, default = number, max = number })
  })
}

variable "emergency" {
  description = "Surge capacity applied by 'on'."
  type = object({
    min_tasks = number
    max_tasks = number
    min_acu   = number
    max_acu   = number
    ttl       = object({ min = number, default = number, max = number })
  })

  validation {
    condition     = var.emergency.min_acu >= 0.5 && var.emergency.ttl.min > 0
    error_message = "Emergency Mode must keep Aurora awake (min_acu >= 0.5) and force edge caching (ttl.min > 0)."
  }
}

variable "auto_trigger_requests_per_minute" {
  description = "Turn Emergency Mode on automatically above this many edge requests/minute. 0 disables."
  type        = number
  default     = 0
}

variable "alert_email" {
  description = "Optional address to email when the surge alarm fires."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  type    = number
  default = 30
}
