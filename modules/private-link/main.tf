################################################################################
# Private Link
################################################################################

resource "aws_security_group" "streamsec_privatelink" {
  count       = var.enable_privatelink && var.privatelink_security_group_id == null ? 1 : 0
  name_prefix = "streamsec-privatelink-"
  vpc_id      = var.vpc_id
  description = "Allow HTTPS to StreamSecurity PrivateLink endpoint"

  ingress {
    description = "HTTPS to VPCE ENI targets"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTPS to VPCE ENI targets"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.privatelink_tags
}

resource "aws_vpc_endpoint" "streamsec" {
  count               = var.enable_privatelink ? 1 : 0
  vpc_id              = var.vpc_id
  service_name        = var.privatelink_service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  private_dns_enabled = var.enable_privatelink_private_dns
  security_group_ids  = [local._pl_sg_id]

  tags = merge(
    { Name = "streamsec-privatelink" },
    var.privatelink_tags
  )
}