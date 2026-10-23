variable "instances_per_region" {
  description = "Generators per region (3 regions). 2 x c7g.xlarge per region comfortably drives ~18k req/s total."
  type        = number
  default     = 2
}

variable "instance_type" {
  description = "Graviton instance type. Check the 'Running On-Demand Standard instances' vCPU quota in each region first."
  type        = string
  default     = "c7g.xlarge"
}

variable "k6_version" {
  description = "k6 release installed on each generator."
  type        = string
  default     = "0.54.0"
}
