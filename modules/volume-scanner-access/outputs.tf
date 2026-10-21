output "role_arn" {
  description = "ARN of StreamScannerSpokeRole, the role the hub's scanner assumes to scan this account"
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the role the hub's scanner assumes: always StreamScannerSpokeRole"
  value       = aws_iam_role.this.name
}

output "hub_cloud_account_id" {
  description = "12-digit id of the hub's AWS account, the only account the role trusts"
  value       = data.streamsec_aws_scanner_hub_access.this.hub_cloud_account_id
}
