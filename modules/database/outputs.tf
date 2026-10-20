output "cluster_id" {
  value = aws_rds_cluster.this.cluster_identifier
}

output "cluster_arn" {
  value = aws_rds_cluster.this.arn
}

output "endpoint" {
  value = aws_rds_cluster.this.endpoint
}

output "database_name" {
  value = aws_rds_cluster.this.database_name
}

output "master_username" {
  value = aws_rds_cluster.this.master_username
}

output "master_secret_arn" {
  value = aws_rds_cluster.this.master_user_secret[0].secret_arn
}

output "min_acu" {
  value = var.min_acu
}

output "max_acu" {
  value = var.max_acu
}

output "seconds_until_auto_pause" {
  value = var.seconds_until_auto_pause
}
