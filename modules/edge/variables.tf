variable "name" {
  type = string
}

variable "alb_dns_name" {
  type = string
}

variable "origin_verify_secret" {
  type      = string
  sensitive = true
}

variable "normal_ttl" {
  description = "Baseline cache TTLs (seconds) for public pages. Emergency Mode overrides these at runtime."
  type = object({
    min     = number
    default = number
    max     = number
  })
  default = { min = 0, default = 60, max = 86400 }
}

variable "admin_allowed_cidrs" {
  description = "IPv4 and/or IPv6 CIDRs allowed to reach /wp-admin and /wp-login.php (agency office, VPN egress)."
  type        = list(string)

  validation {
    condition     = length(var.admin_allowed_cidrs) > 0
    error_message = "Provide at least one CIDR, or nobody will be able to log in to the CMS."
  }
}

variable "rate_limit_per_5min" {
  description = "Max requests per IP per 5 minutes before WAF blocks it."
  type        = number
  default     = 2000
}

variable "rate_limit_exempt_cidrs" {
  description = "CIDRs exempt from the rate limit — your load-test runners."
  type        = list(string)
  default     = []
}

variable "price_class" {
  description = "PriceClass_100 = US/Canada/Europe edges, enough for a state agency audience."
  type        = string
  default     = "PriceClass_100"
}

variable "aliases" {
  description = "Custom hostnames (requires acm_certificate_arn in us-east-1)."
  type        = list(string)
  default     = []
}

variable "acm_certificate_arn" {
  type    = string
  default = null
}
