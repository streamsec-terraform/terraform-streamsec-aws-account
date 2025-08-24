################################################################################
# Private Link
################################################################################

output "privatelink_vpce_id" {
  value       = try(aws_vpc_endpoint.streamsec[0].id, null)
  description = "The Interface VPC Endpoint ID"
}

output "privatelink_dns_entries" {
  value       = try(aws_vpc_endpoint.streamsec[0].dns_entry, null)
  description = "DNS entries for the endpoint (includes the private hosted zone name when private DNS is enabled)"
}

output "privatelink_security_group_id" {
  value       = local.pl_sg_id
  description = "Security Group used for PrivateLink"
}

# Output the extracted DNS name
output "streamsec_endpoint" {
  description = "The StreamSecurity DNS endpoint for the VPC Endpoint"
  value       = local.streamsec_dns
}
