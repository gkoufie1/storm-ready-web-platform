resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "Aurora MySQL: reachable only from the CMS tasks"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from CMS tasks"
  referenced_security_group_id = var.app_security_group_id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
}

# Audit who connected and every schema/permission change (DDL/DCL) — the
# record an agency security review will ask for.
resource "aws_rds_cluster_parameter_group" "this" {
  name   = "${var.name}-aurora-mysql8"
  family = "aurora-mysql8.0"

  parameter {
    name  = "server_audit_logging"
    value = "1"
  }

  parameter {
    name  = "server_audit_events"
    value = "CONNECT,QUERY_DDL,QUERY_DCL"
  }
}

resource "aws_rds_cluster" "this" {
  cluster_identifier = "${var.name}-aurora"
  engine             = "aurora-mysql"
  engine_mode        = "provisioned"
  engine_version     = var.engine_version
  database_name      = "wordpress"
  master_username    = "wpadmin"

  # RDS generates and stores the password in Secrets Manager; it never
  # touches Terraform state or the task definition.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  storage_encrypted      = true

  backup_retention_period   = var.backup_retention_days
  preferred_backup_window   = "07:00-08:00"
  copy_tags_to_snapshot     = true
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = !var.deletion_protection
  final_snapshot_identifier = var.deletion_protection ? "${var.name}-aurora-final" : null

  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name
  enabled_cloudwatch_logs_exports = ["audit", "error", "slowquery"]

  serverlessv2_scaling_configuration {
    min_capacity             = var.min_acu
    max_capacity             = var.max_acu
    seconds_until_auto_pause = var.min_acu == 0 ? var.seconds_until_auto_pause : null
  }

  lifecycle {
    # Runtime capacity is owned by the Emergency Mode Lambda once deployed;
    # it restores these baseline values when emergency mode is turned off.
    ignore_changes = [serverlessv2_scaling_configuration]
  }
}

resource "aws_rds_cluster_instance" "this" {
  count = var.instance_count

  identifier                 = "${var.name}-aurora-${count.index}"
  cluster_identifier         = aws_rds_cluster.this.id
  instance_class             = "db.serverless"
  engine                     = aws_rds_cluster.this.engine
  engine_version             = aws_rds_cluster.this.engine_version
  db_subnet_group_name       = aws_db_subnet_group.this.name
  auto_minor_version_upgrade = true
}
