################################################################################
# AWS Provider Variables
################################################################################
variable "region" {
  description = "The AWS region to deploy resources in."
  type        = string
}

################################################################################
# Stream Security AWS Account Variables
################################################################################

variable "streamsec_account" {
  description = "The AWS Account ID for the Stream.Security account."
  type        = string
  default     = "624907860825"
}

variable "aws_account_display_name" {
  description = "The display name for the AWS account to be protected by Stream.Security."
  type        = string
}

variable "aws_account_regions" {
  description = "The AWS regions for the AWS account to be protected by Stream.Security."
  type        = list(string)
}

################################################################################
# Stream Security IAM Role
################################################################################
variable "iam_role_name" {
  description = "Name to use on IAM role created"
  type        = string
  default     = "streamsec-role"
}

variable "iam_role_description" {
  description = "Description to use on IAM role created"
  type        = string
  default     = "Stream Security IAM Role"
}

variable "iam_role_use_name_prefix" {
  description = "Determines whether the IAM role name (`iam_role_name`) is used as a prefix"
  type        = bool
  default     = true
}

variable "iam_role_path" {
  description = "Cluster IAM role path"
  type        = string
  default     = null
}

variable "iam_role_tags" {
  description = "A map of additional tags to add to the IAM role created"
  type        = map(string)
  default     = {}
}

################################################################################
# Stream Security IAM Policies
################################################################################

variable "iam_policy_name" {
  description = "Name to use on IAM policy created"
  type        = string
  default     = "streamsec-policy"
}

variable "iam_policy_description" {
  description = "Description to use on IAM policy created"
  type        = string
  default     = "Stream Security IAM Policy"
}

variable "iam_policy_use_name_prefix" {
  description = "Determines whether the IAM policy name (`iam_policy_name`) is used as a prefix"
  type        = bool
  default     = true
}

variable "iam_policy_path" {
  description = "IAM policy path"
  type        = string
  default     = null
}

variable "iam_policy_tags" {
  description = "A map of additional tags to add to the IAM policy created"
  type        = map(string)
  default     = {}
}

################################################################################
# Stream Security cloudtrail
################################################################################

variable "create_cloudtrail" {
  description = "Whether to create a CloudTrail for the AWS account"
  type        = bool
  default     = false
}

variable "cloudtrail_name" {
  description = "Name of the CloudTrail to create"
  type        = string
  default     = "streamsec-real-time-cloudtrail"
}

variable "cloudtrail_bucket_name" {
  description = "The name of the S3 bucket to store CloudTrail logs in"
  type        = string
  default     = "streamsec-cloudtrail"
}

variable "cloudtrail_bucket_use_name_prefix" {
  description = "Determines whether the CloudTrail bucket name (`cloudtrail_bucket_name`) is used as a prefix"
  type        = bool
  default     = true
}

variable "cloudtrail_bucket_force_destroy" {
  description = "A boolean that indicates all objects should be deleted from the bucket so that the bucket can be destroyed without error"
  type        = bool
  default     = true
}

variable "cloudtrail_bucket_tags" {
  description = "tags for cloudtrail bucket"
  type        = map(string)
  default     = {}
}

variable "cloudtrail_tags" {
  description = "tags for cloudtrail"
  type        = map(string)
  default     = {}
}

################################################################################
# General
################################################################################

variable "tags" {
  description = "A map of global tags to add to all created resources"
  type        = map(string)
  default     = {}
}
