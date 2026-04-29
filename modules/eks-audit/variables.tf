################################################################################
# EKS Audit Collector
################################################################################

variable "resource_prefix" {
  description = "Optional prefix prepended before StreamSecurity in all resource names"
  type        = string
  default     = ""
}

variable "eks_include_clusters" {
  description = "Only subscribe these EKS clusters. If empty, all clusters in the region are included."
  type        = list(string)
  default     = []
}

variable "eks_exclude_clusters" {
  description = "Skip these EKS clusters from subscription"
  type        = list(string)
  default     = []
}

variable "collection_token_secret_name" {
  description = "Base name for the Secrets Manager secret storing the collection token"
  type        = string
  default     = "lightlytics-eks-collection-token"
}

variable "collector_lambda_memory_size" {
  description = "The amount of memory in MB to allocate to the collector Lambda function"
  type        = number
  default     = 128
}

variable "collector_lambda_timeout" {
  description = "The amount of time in seconds the collector Lambda function is allowed to run"
  type        = number
  default     = 10
}

variable "lambda_log_retention_days" {
  description = "The number of days to retain the collector Lambda CloudWatch logs"
  type        = number
  default     = 1
}

variable "collector_role_arn" {
  description = "If set, skip IAM role creation and use this existing role ARN for the collector Lambda"
  type        = string
  default     = null
  validation {
    condition     = var.collector_role_arn == null || can(regex("^arn:aws:iam::", var.collector_role_arn))
    error_message = "collector_role_arn must be a valid IAM role ARN starting with arn:aws:iam::."
  }
}

################################################################################
# General
################################################################################

variable "tags" {
  description = "A map of global tags to add to all created resources"
  type        = map(string)
  default     = {}
}
