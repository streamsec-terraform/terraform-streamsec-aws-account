output "cluster_arn" {
  description = "ARN of the ECS cluster running the scanner tasks"
  value       = aws_ecs_cluster.this.arn
}

output "task_definition_arn" {
  description = "ARN of the scanner task definition (current revision)"
  value       = aws_ecs_task_definition.this.arn
}

output "task_definition_family_arn" {
  description = "Revision-less family ARN of the scanner task definition — what the orchestrator uses to launch child tasks on the current ACTIVE revision"
  value       = local.task_definition_family_arn
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
