variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Data-tier subnets (no internet route)."
  type        = list(string)
}

variable "app_security_group_id" {
  description = "Security group of the CMS tasks allowed to connect."
  type        = string
}

variable "engine_version" {
  description = "Aurora MySQL version. 3.08.0+ is required for scale-to-zero (min_acu = 0)."
  type        = string
  default     = "8.0.mysql_aurora.3.08.0"
}

variable "min_acu" {
  description = "Baseline minimum Aurora capacity units. 0 lets the cluster auto-pause when idle."
  type        = number
  default     = 0
}

variable "max_acu" {
  description = "Baseline maximum Aurora capacity units."
  type        = number
  default     = 4
}

variable "seconds_until_auto_pause" {
  description = "Idle seconds before pausing (only used when min_acu = 0)."
  type        = number
  default     = 900
}

variable "instance_count" {
  description = "1 = writer only. 2+ adds readers in other AZs for failover."
  type        = number
  default     = 1
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "deletion_protection" {
  description = "Block deletes and take a final snapshot on destroy."
  type        = bool
  default     = false
}
