variable "admin_allowed_cidrs" {
  description = "Networks allowed to reach wp-admin. Set in terraform.tfvars or TF_VAR_admin_allowed_cidrs."
  type        = list(string)
}

variable "rate_limit_exempt_cidrs" {
  description = "Load-test runner IPs exempt from the WAF per-IP rate limit."
  type        = list(string)
  default     = []
}

variable "alert_email" {
  type    = string
  default = ""
}

variable "custom_domain" {
  description = "Custom hostname (e.g. demo.epixdevo.org). Its ACM certificate must already be ISSUED — see bootstrap/. Empty = use the CloudFront domain."
  type        = string
  default     = ""
}
