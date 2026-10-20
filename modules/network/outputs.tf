output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "data_subnet_ids" {
  value = aws_subnet.data[*].id
}

# Where Fargate tasks should run: private app subnets when a NAT gateway
# exists, otherwise the public subnets (tasks then get a public IP).
output "app_subnet_ids" {
  value = var.enable_nat_gateway ? aws_subnet.app[*].id : aws_subnet.public[*].id
}

output "app_tasks_need_public_ip" {
  value = !var.enable_nat_gateway
}
