locals {
  _pl_sg_id = var.privatelink_security_group_id != null ? var.privatelink_security_group_id : (var.enable_privatelink ? aws_security_group.streamsec_privatelink[0].id : null)

    streamsec_api_url = (var.enable_privatelink && try(length(var.privatelink_service_name) > 0, false)) ? var.privatelink_service_name : data.streamsec_host.this.url
}