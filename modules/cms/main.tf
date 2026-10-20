data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# ── Security groups ──

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "ALB: HTTP only from CloudFront origin-facing IPs"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from CloudFront edge"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "HTTP to CMS tasks"
  referenced_security_group_id = aws_security_group.tasks.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "tasks" {
  name        = "${var.name}-cms-tasks"
  description = "CMS tasks: HTTP only from the ALB"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "HTTP from ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

# Outbound HTTPS for image pulls, Secrets Manager and WordPress.org updates;
# MySQL and NFS stay inside the VPC.
resource "aws_vpc_security_group_egress_rule" "tasks_https" {
  security_group_id = aws_security_group.tasks.id
  description       = "HTTPS out (image pulls, AWS APIs, wordpress.org)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "tasks_mysql" {
  security_group_id = aws_security_group.tasks.id
  description       = "MySQL to Aurora"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 3306
  to_port           = 3306
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "tasks_nfs" {
  security_group_id = aws_security_group.tasks.id
  description       = "NFS to EFS"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 2049
  to_port           = 2049
  ip_protocol       = "tcp"
}

resource "aws_security_group" "efs" {
  name        = "${var.name}-efs"
  description = "EFS: NFS only from the CMS tasks"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_tasks" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS from CMS tasks"
  referenced_security_group_id = aws_security_group.tasks.id
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
}

# ── Load balancer ──

resource "aws_lb" "this" {
  name                       = "${var.name}-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.public_subnet_ids
  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection
}

resource "aws_lb_target_group" "cms" {
  name                 = "${var.name}-cms"
  port                 = 80
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  # A static file served by Apache: proves the container is up without
  # making ALB health depend on Aurora resuming from auto-pause.
  health_check {
    path                = "/wp-includes/images/blank.gif"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# Anything that didn't come through CloudFront (no secret header) gets 403.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "from_cloudfront" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [var.origin_verify_secret]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.cms.arn
  }
}

# ── Shared wp-content on EFS (uploads, plugins, themes across all tasks) ──

resource "aws_efs_file_system" "wp_content" {
  creation_token = "${var.name}-wp-content"
  encrypted      = true

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = { Name = "${var.name}-wp-content" }
}

resource "aws_efs_mount_target" "wp_content" {
  count           = length(var.data_subnet_ids)
  file_system_id  = aws_efs_file_system.wp_content.id
  subnet_id       = var.data_subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}

# uid/gid 33 = www-data in the official WordPress image.
resource "aws_efs_access_point" "wp_content" {
  file_system_id = aws_efs_file_system.wp_content.id

  posix_user {
    uid = 33
    gid = 33
  }

  root_directory {
    path = "/wp-content"
    creation_info {
      owner_uid   = 33
      owner_gid   = 33
      permissions = "0755"
    }
  }
}

# ── Secrets: WordPress auth keys/salts must match on every task or logins
#    break as requests bounce between tasks. ──

locals {
  salt_names = [
    "AUTH_KEY", "SECURE_AUTH_KEY", "LOGGED_IN_KEY", "NONCE_KEY",
    "AUTH_SALT", "SECURE_AUTH_SALT", "LOGGED_IN_SALT", "NONCE_SALT",
  ]
}

resource "random_password" "salts" {
  for_each = toset(local.salt_names)
  length   = 64
  special  = false
}

resource "aws_secretsmanager_secret" "salts" {
  name                    = "${var.name}/wordpress-salts"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "salts" {
  secret_id     = aws_secretsmanager_secret.salts.id
  secret_string = jsonencode({ for k in local.salt_names : k => random_password.salts[k].result })
}

# ── IAM ──

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-cms-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn, aws_secretsmanager_secret.salts.arn]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-cms-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

resource "aws_iam_role" "task" {
  name               = "${var.name}-cms-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "task" {
  statement {
    sid = "EfsMount"
    actions = [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientWrite",
    ]
    resources = [aws_efs_file_system.wp_content.arn]
    condition {
      test     = "StringEquals"
      variable = "elasticfilesystem:AccessPointArn"
      values   = [aws_efs_access_point.wp_content.arn]
    }
  }

  # ECS Exec, for running WP-CLI inside a live task.
  statement {
    sid = "EcsExec"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "cms-task"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# ── ECS ──

resource "aws_cloudwatch_log_group" "cms" {
  name              = "/ecs/${var.name}/cms"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "this" {
  name = "${var.name}-cluster"

  setting {
    name  = "containerInsights"
    value = var.container_insights ? "enabled" : "disabled"
  }
}

locals {
  # Viewers only ever reach WordPress through CloudFront over HTTPS (the
  # viewer protocol policy redirects HTTP), so tell WordPress it's on HTTPS
  # and pin its URLs to the public domain rather than the ALB hostname.
  wp_config_extra = <<-PHP
    $_SERVER['HTTPS'] = 'on';
    define('WP_HOME', 'https://${var.site_domain}');
    define('WP_SITEURL', 'https://${var.site_domain}');
    define('DISALLOW_FILE_EDIT', true);
    define('FORCE_SSL_ADMIN', true);
  PHP
}

resource "aws_ecs_task_definition" "cms" {
  family                   = "${var.name}-cms"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  volume {
    name = "wp-content"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.wp_content.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.wp_content.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = "wordpress"
      image     = var.container_image
      essential = true

      portMappings = [{ containerPort = 80, protocol = "tcp" }]

      environment = [
        { name = "WORDPRESS_DB_HOST", value = var.db_endpoint },
        { name = "WORDPRESS_DB_NAME", value = var.db_name },
        { name = "WORDPRESS_DB_USER", value = var.db_username },
        { name = "WORDPRESS_CONFIG_EXTRA", value = local.wp_config_extra },
      ]

      secrets = concat(
        [{ name = "WORDPRESS_DB_PASSWORD", valueFrom = "${var.db_secret_arn}:password::" }],
        [for k in local.salt_names : {
          name      = "WORDPRESS_${k}"
          valueFrom = "${aws_secretsmanager_secret.salts.arn}:${k}::"
        }],
      )

      mountPoints = [{
        sourceVolume  = "wp-content"
        containerPath = "/var/www/html/wp-content"
        readOnly      = false
      }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.cms.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "wordpress"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "cms" {
  name                   = "${var.name}-cms"
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.cms.arn
  desired_count          = var.min_tasks
  launch_type            = "FARGATE"
  enable_execute_command = true

  health_check_grace_period_seconds = 120

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = var.assign_public_ip
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.cms.arn
    container_name   = "wordpress"
    container_port   = 80
  }

  depends_on = [aws_lb_listener_rule.from_cloudfront, aws_efs_mount_target.wp_content]

  lifecycle {
    # Auto-scaling (and Emergency Mode) own the running count.
    ignore_changes = [desired_count]
  }
}

# ── Auto-scaling ──

resource "aws_appautoscaling_target" "cms" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.cms.name}"
  min_capacity       = var.min_tasks
  max_capacity       = var.max_tasks

  lifecycle {
    # Emergency Mode raises these at runtime and restores them afterwards.
    ignore_changes = [min_capacity, max_capacity]
  }
}

resource "aws_appautoscaling_policy" "requests" {
  name               = "${var.name}-cms-requests"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.cms.service_namespace
  scalable_dimension = aws_appautoscaling_target.cms.scalable_dimension
  resource_id        = aws_appautoscaling_target.cms.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.target_requests_per_task
    scale_in_cooldown  = 300
    scale_out_cooldown = 30

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.this.arn_suffix}/${aws_lb_target_group.cms.arn_suffix}"
    }
  }
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-cms-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.cms.service_namespace
  scalable_dimension = aws_appautoscaling_target.cms.scalable_dimension
  resource_id        = aws_appautoscaling_target.cms.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 30

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
