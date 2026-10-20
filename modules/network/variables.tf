variable "name" {
  description = "Name prefix for all resources, e.g. storm-ready-staging."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR. Must be a /16 — subnets are carved as /24s."
  type        = string
}

variable "availability_zones" {
  description = "Two or more AZs to spread subnets across."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least two AZs are required (ALB and Aurora both need them)."
  }
}

variable "enable_nat_gateway" {
  description = "Create a NAT gateway so app tasks can run in private subnets."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Retention for VPC flow logs."
  type        = number
  default     = 30
}
