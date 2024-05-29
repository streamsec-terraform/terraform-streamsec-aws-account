################################################################################
# Stream Security API Variables
################################################################################

variable "domain" {
  description = "The domain name for the Stream.Security API. EXAMPLE: app.streamsec.io"
  type        = string
}

variable "username" {
  description = "The username the Stream.Security API."
  type        = string
}

variable "password" {
  description = "The password for the Stream.Security API."
  type        = string
  sensitive = true
}

variable "workspace_id" {
    description = "The workspace ID for the Stream.Security API."
    type        = string
}

################################################################################
# Stream Security AWS Account Variables
################################################################################
variable "aws_account_id" {
  description = "The AWS Account ID for the AWS account to be protected by Stream.Security."
  type        = string
}

variable "aws_account_display_name" {
  description = "The display name for the AWS account to be protected by Stream.Security."
  type        = string
}

variable "aws_account_regions" {
    description = "The AWS regions for the AWS account to be protected by Stream.Security."
    type        = list(string)
}