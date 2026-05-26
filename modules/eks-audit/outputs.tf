output "collector_lambda_arn" {
  description = "ARN of the EKS audit collector Lambda function"
  value       = aws_lambda_function.collector.arn
}

output "collector_lambda_name" {
  description = "Name of the EKS audit collector Lambda function"
  value       = aws_lambda_function.collector.function_name
}

output "collector_role_arn" {
  description = "ARN of the IAM role used by the collector Lambda"
  value       = local.role_arn
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret storing the collection token"
  value       = aws_secretsmanager_secret.collection_token.arn
}

output "subscribed_clusters" {
  description = "List of EKS cluster names that have subscription filters"
  value       = local.target_clusters
}
