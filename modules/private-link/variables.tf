################################################################################
# Private Link
################################################################################

variable "enable_privatelink" {
  description = "Create an Interface VPC Endpoint for StreamSecurity"
  type        = bool
  default     = false
}

variable "privatelink_service_name" {
  description = "StreamSecurity AWS PrivateLink service name for your region (from StreamSecurity)"
  type        = string
  default     = null
}

variable "vpc_id" {
  description = "VPC ID where the Interface Endpoint will be created"
  type        = string
  default     = null
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the Interface Endpoint"
  type        = list(string)
  default     = []
}

variable "privatelink_security_group_id" {
  description = "Optional existing SG ID allowing egress 443 to the endpoint. If null, the module creates one."
  type        = string
  default     = null
}

variable "enable_privatelink_private_dns" {
  description = "Enable Private DNS on the VPC Endpoint (recommended)"
  type        = bool
  default     = true
}

variable "privatelink_tags" {
  description = "Tags for PrivateLink resources"
  type        = map(string)
  default     = {}
}
