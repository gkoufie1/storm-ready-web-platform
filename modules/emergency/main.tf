data "aws_caller_identity" "current" {}

locals {
  parameter_name = "/${var.name}/emergency-mode"

  # The Lambda's whole world: what to touch, and the two profiles to apply.
  config = {
    parameter_name = local.parameter_name
    ecs = {
      resource_id = var.ecs_resource_id
      on          = { min = var.emergency.min_tasks, max = var.emergency.max_tasks }
      off         = { min = var.baseline.min_tasks, max = var.baseline.max_tasks }
    }
    aurora = {
      cluster_id = var.db_cluster_id
      on         = { min = var.emergency.min_acu, max = var.emergency.max_acu, auto_pause_seconds = var.baseline.auto_pause_seconds }
      off        = { min = var.baseline.min_acu, max = var.baseline.max_acu, auto_pause_seconds = var.baseline.auto_pause_seconds }
    }
    cloudfront = {
      cache_policy_id = var.cache_policy_id
      on              = var.emergency.ttl
      off             = var.baseline.ttl
    }
  }
}

resource "aws_ssm_parameter" "state" {
  name        = local.parameter_name
  description = "Current Emergency Mode state, written by the Lambda"
  type        = "String"
  value       = jsonencode({ mode = "off", requested_by = "terraform" })

  lifecycle {
    ignore_changes = [value]
  }
}

# ── Lambda ──

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda/emergency_mode"
  output_path = "${path.module}/../../build/emergency_mode.zip"
  excludes    = ["test_handler.py", "__pycache__"]
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name}-emergency-mode"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }

  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }

  statement {
    sid       = "State"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [aws_ssm_parameter.state.arn]
  }

  # Application Auto Scaling has no resource-level permissions for these.
  statement {
    sid = "EcsScaling"
    actions = [
      "application-autoscaling:RegisterScalableTarget",
      "application-autoscaling:DescribeScalableTargets",
    ]
    resources = ["*"]
  }

  # RegisterScalableTarget calls these on the caller's behalf.
  statement {
    sid       = "EcsService"
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = [var.ecs_service_arn]
  }

  statement {
    sid       = "Aurora"
    actions   = ["rds:ModifyDBCluster", "rds:DescribeDBClusters"]
    resources = [var.db_cluster_arn]
  }

  statement {
    sid     = "CachePolicy"
    actions = ["cloudfront:GetCachePolicyConfig", "cloudfront:UpdateCachePolicy"]
    resources = [
      "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:cache-policy/${var.cache_policy_id}",
    ]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "emergency-mode"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name}-emergency-mode"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "this" {
  function_name    = "${var.name}-emergency-mode"
  description      = "Flip the platform into / out of surge-ready Emergency Mode"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 60

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      CONFIG = jsonencode(local.config)
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy.lambda]
}

# ── Optional auto-trigger: CloudFront request surge → SNS → Lambda ──

resource "aws_sns_topic" "surge" {
  name = "${var.name}-traffic-surge"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.surge.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_subscription" "lambda" {
  count     = var.auto_trigger_requests_per_minute > 0 ? 1 : 0
  topic_arn = aws_sns_topic.surge.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.this.arn
}

resource "aws_lambda_permission" "sns" {
  count         = var.auto_trigger_requests_per_minute > 0 ? 1 : 0
  statement_id  = "AllowSurgeTopic"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.surge.arn
}

resource "aws_cloudwatch_metric_alarm" "surge" {
  count               = var.auto_trigger_requests_per_minute > 0 ? 1 : 0
  alarm_name          = "${var.name}-traffic-surge"
  alarm_description   = "Edge requests are surging - turns Emergency Mode ON (never off)"
  namespace           = "AWS/CloudFront"
  metric_name         = "Requests"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = var.auto_trigger_requests_per_minute
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DistributionId = var.distribution_id
    Region         = "Global"
  }

  alarm_actions = [aws_sns_topic.surge.arn]
  ok_actions    = [aws_sns_topic.surge.arn]
}
