output "cloudwatch_alarm_arn" {
  value       = aws_cloudwatch_metric_alarm.ebs_usage_high.arn
  description = "ARN of the high-disk-usage CloudWatch alarm."
}

output "step_function_arn" {
  value       = aws_sfn_state_machine.ebs_expansion.arn
  description = "ARN of the Step Functions state machine that performs the resize."
}

output "resize_lambda_name" {
  value       = module.resize_lambda.lambda_function_name
  description = "Name of the Lambda that calls ModifyVolume."
}

output "event_rule_name" {
  value       = aws_cloudwatch_event_rule.ebs_high_usage.name
  description = "EventBridge rule that triggers the workflow."
}
