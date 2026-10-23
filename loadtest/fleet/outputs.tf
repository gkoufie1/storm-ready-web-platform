output "instances" {
  description = "Generator instance IDs by region (read by run.py)."
  value = {
    "us-east-1" = module.use1.instance_ids
    "us-east-2" = module.use2.instance_ids
    "us-west-2" = module.usw2.instance_ids
  }
}

output "results_bucket" {
  value = aws_s3_bucket.results.bucket
}
