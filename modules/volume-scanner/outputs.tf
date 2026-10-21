output "cluster_arn" {
  description = "ARN of the ECS cluster running the scanner tasks"
  value       = aws_ecs_cluster.this.arn
}

output "task_definition_arn" {
  description = "ARN of the orchestrator task definition (current revision) — the one the schedule and the initial scan start"
  value       = aws_ecs_task_definition.this.arn
}

output "task_definition_family_arn" {
  description = "Revision-less family ARN of the orchestrator task definition"
  value       = local.task_definition_family_arn
}

output "worker_task_definition_arn" {
  description = "ARN of the worker task definition (current revision), which runs the instance shards and the workload scan"
  value       = aws_ecs_task_definition.worker.arn
}

output "worker_task_definition_family_arn" {
  description = "Revision-less family ARN of the worker task definition — what the orchestrator uses to launch workers on the current ACTIVE revision"
  value       = local.worker_task_definition_family_arn
}

output "log_group_name" {
  description = "CloudWatch log group receiving the scanner container logs"
  value       = aws_cloudwatch_log_group.this.name
}

output "security_group_id" {
  description = "ID of the scanner's egress-only security group"
  value       = aws_security_group.this.id
}

output "task_role_arn" {
  description = "ARN of the IAM role the scanner task assumes"
  value       = aws_iam_role.task.arn
}

output "scanner_vpc_id" {
  description = "ID of the VPC the scanner runs in — the one this module created, or the vpc_id that was supplied"
  value       = local.scanner_vpc_id
}

output "scanner_subnet_ids" {
  description = "Subnets the scanner Fargate tasks run in"
  value       = local.scanner_subnet_ids
}

output "nat_gateway_public_ip" {
  description = "Stable egress IP of the scanner's NAT Gateway, for allowlisting in upstream firewalls. Null when create_scanner_vpc is false, since egress is then through infrastructure this module does not own."
  value       = var.create_scanner_vpc ? aws_eip.nat[0].public_ip : null
}

output "collection_token_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the scanner's collection token"
  value       = aws_secretsmanager_secret.collection_token.arn
}

output "collection_token_secret_name" {
  description = "Name of the Secrets Manager secret holding the scanner's collection token. Carries a generated suffix, so read it from here rather than reconstructing it."
  value       = aws_secretsmanager_secret.collection_token.name
}
