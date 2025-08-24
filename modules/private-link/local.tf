locals {
  pl_sg_id      = var.privatelink_security_group_id != null ? var.privatelink_security_group_id : (var.enable_privatelink ? aws_security_group.streamsec_privatelink[0].id : null)
  streamsec_dns = var.enable_privatelink ? [for entry in aws_vpc_endpoint.streamsec[0].dns_entry : entry.dns_name if can(regex("lightlytics\\.com$", entry.dns_name))][0] : null
}
