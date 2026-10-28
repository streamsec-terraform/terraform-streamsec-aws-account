variable "workspace_id" {
  description = "Stream Security workspace id, the same value as the streamsec provider's workspace_id"
  type        = string
}

variable "spoke_admin_role_arn" {
  description = "A role in the spoke account that may create IAM roles, for Terraform to assume"
  type        = string
}
