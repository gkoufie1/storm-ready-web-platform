# One region's worth of load generators: a throwaway VPC with a public
# subnet (outbound only — no inbound rules) and N instances managed via SSM.

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "cidr" {
  type = string
}

variable "instance_count" {
  type = number
}

variable "instance_type" {
  type = string
}

variable "instance_profile_name" {
  type = string
}

variable "user_data" {
  type = string
}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# Not every AZ offers every instance type (e.g. some us-east-1 AZs).
data "aws_ec2_instance_type_offerings" "available" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "storm-ready-loadtest" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
}

resource "aws_subnet" "this" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.cidr
  availability_zone       = sort(data.aws_ec2_instance_type_offerings.available.locations)[0]
  map_public_ip_on_launch = true
}

resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.this.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "this" {
  subnet_id      = aws_subnet.this.id
  route_table_id = aws_route_table.this.id
}

resource "aws_security_group" "generator" {
  name_prefix = "storm-ready-loadtest-"
  description = "Load generators: no inbound, HTTPS out only"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.generator.id
  description       = "HTTPS to the target site, SSM, S3, package and k6 downloads"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_instance" "generator" {
  count = var.instance_count

  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.this.id
  vpc_security_group_ids = [aws_security_group.generator.id]
  iam_instance_profile   = var.instance_profile_name
  user_data              = var.user_data

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 8
    encrypted   = true
  }

  tags = { Name = "storm-ready-loadtest-${count.index}" }

  depends_on = [aws_route.internet]
}

output "instance_ids" {
  value = aws_instance.generator[*].id
}
