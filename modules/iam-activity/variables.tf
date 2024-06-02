################################################################################
# Stream Security FlowLogs lambda
################################################################################

variable "collection_iam_activity_token_secret_name" {
  description = "The name of the secret to use for the lambda function"
  type        = string
  default     = "streamsec-collection-token-iam-activity"
}

variable "lambda_collection_token" {
  description = "The collection token to use for the lambda function"
  type        = string
}

variable "lambda_name" {
  description = "Name of the lambda function"
  type        = string
  default     = "streamsec-iam-activity-lambda"
}

variable "lambda_cloudwatch_memory_size" {
  description = "The amount of memory in MB to allocate to the lambda function"
  type        = number
  default     = 128
}

variable "lambda_cloudwatch_timeout" {
  description = "The amount of time in seconds the lambda function is allowed to run"
  type        = number
  default     = 60
}

variable "lambda_batch_size" {
  default = 4000
}

variable "lambda_source_code_bucket_prefix" {
  description = "The prefix to use for the lambda source code bucket"
  type        = string
  default     = "prod-lightlytics-artifacts"
}

variable "lambda_cloudwatch_s3_source_code_key" {
  description = "The S3 key for the lambda source code"
  type        = string
  default     = "6c0c66c12749eb83543b83c0b2c27e69"
}

variable "lambda_layer_name" {
  description = "The name of the lambda layer"
  type        = string
  default     = "streamsec-iam-activity-layer"
}

variable "lambda_layer_s3_source_code_key" {
  description = "The S3 key for the lambda source code"
  type        = string
  default     = "24ad10212c195b9a805df9b82493877b"
}

variable "lambda_subnet_ids" {
  description = "The subnet IDs to use for the lambda function"
  type        = list(string)
  default     = []
}

variable "lambda_security_group_ids" {
  description = "The security group IDs to use for the lambda function"
  type        = list(string)
  default     = []
}

variable "lambda_tags" {
  description = "A map of additional tags to add to the lambda function created"
  type        = map(string)
  default     = {}
}

variable "lambda_cloudwatch_max_event_age" {
  description = "The maximum age of a request that Lambda sends to a function for processing, in seconds"
  type        = number
  default     = 21600
}

variable "lambda_cloudwatch_max_retry" {
  description = "The maximum number of times to retry when the function returns an error"
  type        = number
  default     = 2
}

variable "lambda_iam_role_name" {
  description = "Name to use on IAM role created"
  type        = string
  default     = "streamsec-iam-activity-execution-role"
}

variable "lambda_iam_role_description" {
  description = "Description to use on IAM role created"
  type        = string
  default     = "Stream Security IAM Role"
}

variable "lambda_iam_role_use_name_prefix" {
  description = "Determines whether the IAM role name (`iam_role_name`) is used as a prefix"
  type        = bool
  default     = true
}

variable "lambda_iam_role_path" {
  description = "Cluster IAM role path"
  type        = string
  default     = null
}

variable "lambda_iam_role_tags" {
  description = "A map of additional tags to add to the IAM role created"
  type        = map(string)
  default     = {}
}

variable "lambda_policy_name" {
  description = "Name to use on IAM policy created"
  type        = string
  default     = "streamsec-iam-activity-policy"
}

variable "lambda_policy_description" {
  description = "Description to use on IAM policy created"
  type        = string
  default     = "Stream Security IAM Policy for iam_activity lambda"
}

variable "lambda_policy_use_name_prefix" {
  description = "Determines whether the IAM policy name (`iam_policy_name`) is used as a prefix"
  type        = bool
  default     = true
}

variable "lambda_policy_path" {
  description = "IAM policy path"
  type        = string
  default     = null
}

################################################################################
# IAM Activity S3
################################################################################

variable "iam_activity_bucket_name" {
  description = "The name of the S3 bucket to store the iam activity logs"
  type        = string
}

################################################################################
# General
################################################################################

variable "tags" {
  description = "A map of global tags to add to all created resources"
  type        = map(string)
  default     = {}
}
