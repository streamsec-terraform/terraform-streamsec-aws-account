module "privatelink" {
  source = "../private-link"

  enable_privatelink             = var.enable_privatelink
  privatelink_service_name       = var.privatelink_service_name
  vpc_id                         = var.vpc_id
  private_subnet_ids             = var.private_subnet_ids
  privatelink_security_group_id  = var.privatelink_security_group_id
  enable_privatelink_private_dns = var.enable_privatelink_private_dns
  privatelink_tags               = var.privatelink_tags

}