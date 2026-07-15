output "lambda_function_arn" {
  description = "ARN of the collector Lambda function. Use as the target of a self-managed EventBridge rule when iam_activity_manage_bucket_notification = false."
  value       = aws_lambda_function.streamsec_iam_activity_lambda.arn
}

output "lambda_function_name" {
  description = "Name of the collector Lambda function. Use in the aws_lambda_permission that allows a self-managed EventBridge rule to invoke it."
  value       = aws_lambda_function.streamsec_iam_activity_lambda.function_name
}

output "lambda_role_arn" {
  description = "ARN of the collector Lambda's execution role, e.g. for allowing it in a restricted KMS key policy or bucket policy."
  value       = aws_iam_role.lambda_execution_role.arn
}
