locals {
  _pl_sg_id = var.privatelink_security_group_id != null ? var.privatelink_security_group_id : (var.enable_privatelink ? aws_security_group.streamsec_privatelink[0].id : null)
}