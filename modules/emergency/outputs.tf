output "function_name" {
  value = aws_lambda_function.this.function_name
}

output "state_parameter" {
  value = aws_ssm_parameter.state.name
}

output "surge_topic_arn" {
  value = aws_sns_topic.surge.arn
}
