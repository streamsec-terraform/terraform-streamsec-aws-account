################################################################################
# Stream Security IAM Activity lambda
################################################################################

variable "collection_iam_activity_token_secret_name" {
  description = "The name of the secret to use for the lambda function"
  type        = string
  default     = "streamsec-collection-token-iam-activity"
}

variable "lambda_name" {
  description = "Name of the lambda function"
  type        = string
  default     = "streamsec-iam-activity-lambda"
}

variable "lambda_cloudwatch_memory_size" {
  description = "The amount of memory in MB to allocate to the lambda function"
  type        = number
  default     = 256
}

variable "lambda_cloudwatch_timeout" {
  description = "The amount of time in seconds the lambda function is allowed to run"
  type        = number
  default     = 60
}

variable "lambda_batch_size" {
  description = "The maximum number of records to include in a single batch"
  type        = number
  default     = 4000
}

variable "lambda_source_code_bucket_prefix" {
  description = "The prefix to use for the lambda source code bucket"
  type        = string
  default     = "prod-lightlytics-artifacts"
}

variable "lambda_cloudwatch_s3_source_code_key" {
  description = "The S3 key for the lambda source code"
  type        = string
  default     = "4a752d836232381fc3c72ac51458c1bc"
}

variable "lambda_layer_name" {
  description = "The name of the lambda layer"
  type        = string
  default     = "streamsec-iam-activity-layer"
}

variable "lambda_layer_s3_source_code_key" {
  description = "The S3 key for the lambda source code"
  type        = string
  default     = "1e8d00c5c5513f60c336658713ee2cd5"
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

variable "lambda_runtime" {
  description = "(optional) overwrite hardcoded lambda compatible_runtimes and lambda_runtime"
  type        = string
  default     = "nodejs22.x"
  nullable    = false
}

variable "lambda_tags" {
  description = "A map of tags to add to the lambda created"
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "iam_policy_tags" {
  description = "A map of additional tags to add to the IAM policy created"
  type        = map(string)
  default     = {}
  nullable    = false
}

################################################################################
# IAM Activity S3
################################################################################

variable "iam_activity_bucket_name" {
  description = "The name of the S3 bucket to store the iam activity logs"
  type        = string
}

variable "iam_activity_s3_eventbridge_trigger" {
  description = "Whether to create an eventbridge trigger for the S3 bucket instead of an event notification. Requires enabling eventbridge on bucket properties, see: https://docs.streamsec.io/docs/configure-s3-event-notifications-with-amazon-eventbridge"
  type        = bool
  default     = false
}

variable "iam_activity_s3_eventbridge_rule_name" {
  description = "The name of the eventbridge rule to create for the S3 bucket"
  type        = string
  default     = "streamsec-iam-activity-s3-eventbridge-rule"
}

variable "iam_activity_s3_eventbridge_rule_description" {
  description = "The description of the eventbridge rule to create for the S3 bucket"
  type        = string
  default     = "Stream Security IAM Activity S3 EventBridge Rule"
}

################################################################################
# API Gateway Access Logs S3 (existing bucket)
################################################################################

variable "apigateway_bucket_name" {
  description = "(Optional) Name of an EXISTING S3 bucket (in the same region as this module's provider) that already receives API Gateway access logs (e.g. delivered via Kinesis Data Firehose). PREREQUISITE: EventBridge notifications must be enabled on the bucket, see: https://docs.streamsec.io/docs/configure-s3-event-notifications-with-amazon-eventbridge. When set, the module creates an EventBridge rule that forwards new objects to the collector Lambda. The bucket is NOT created or modified by this module. Must be a static string known at plan time, and must differ from iam_activity_bucket_name."
  type        = string
  default     = null
  validation {
    condition     = var.apigateway_bucket_name == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.apigateway_bucket_name))
    error_message = "apigateway_bucket_name must be a valid S3 bucket name (3-63 chars, lowercase letters, numbers, dots, hyphens)."
  }
}

variable "apigateway_log_format" {
  description = "The API Gateway access log format string configured on the API stage (JSON or delimited $context.* format). REQUIRED when apigateway_bucket_name is set — the collector uses it to parse the log lines and ignores API Gateway objects without it."
  type        = string
  default     = null
}

variable "apigateway_s3_key_prefix" {
  description = "(Optional) S3 key prefix of the API Gateway access log objects (e.g. the Firehose delivery prefix). When set, the EventBridge rule only matches objects under this prefix, the Lambda's s3:GetObject permission is scoped to it, and the collector filters object keys by it."
  type        = string
  default     = null
}

variable "apigateway_kms_key_arn" {
  description = "(Optional) ARN of the KMS key used to encrypt objects in the API Gateway bucket (SSE-KMS). When set, the Lambda execution role is granted kms:Decrypt on this key."
  type        = string
  default     = null
}

variable "apigateway_s3_eventbridge_rule_name" {
  description = "The name of the EventBridge rule to create for the API Gateway access logs S3 bucket. Defaults to a unique name derived from the bucket name."
  type        = string
  default     = null
}

variable "apigateway_s3_eventbridge_rule_description" {
  description = "The description of the EventBridge rule to create for the API Gateway access logs S3 bucket"
  type        = string
  default     = "Stream Security API Gateway Access Logs S3 EventBridge Rule"
}

################################################################################
# S3 Access Logs S3 (existing bucket)
################################################################################

variable "s3_access_logs_bucket_name" {
  description = "(Optional) Name of an EXISTING S3 bucket (in the same region as this module's provider) that is the target of S3 server access logging. PREREQUISITE: EventBridge notifications must be enabled on the bucket, see: https://docs.streamsec.io/docs/configure-s3-event-notifications-with-amazon-eventbridge. When set, the module creates an EventBridge rule that forwards new objects to the collector Lambda. The bucket is NOT created or modified by this module. Must be a static string known at plan time, and must differ from iam_activity_bucket_name."
  type        = string
  default     = null
  validation {
    condition     = var.s3_access_logs_bucket_name == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.s3_access_logs_bucket_name))
    error_message = "s3_access_logs_bucket_name must be a valid S3 bucket name (3-63 chars, lowercase letters, numbers, dots, hyphens)."
  }
}

variable "s3_access_logs_key_prefix" {
  description = "(Optional) S3 key prefix of the S3 access log objects (the target prefix configured on server access logging). When set, the EventBridge rule only matches objects under this prefix and the Lambda's s3:GetObject permission is scoped to it."
  type        = string
  default     = null
}

variable "s3_access_logs_kms_key_arn" {
  description = "(Optional) ARN of the KMS key used to encrypt objects in the S3 access logs bucket (SSE-KMS). When set, the Lambda execution role is granted kms:Decrypt on this key."
  type        = string
  default     = null
}

################################################################################
# ALB Access Logs S3 (existing bucket)
################################################################################

variable "alb_access_logs_bucket_name" {
  description = "(Optional) Name of an EXISTING S3 bucket (in the same region as this module's provider) that is the target of ALB/ELB access logging. PREREQUISITE: EventBridge notifications must be enabled on the bucket, see: https://docs.streamsec.io/docs/configure-s3-event-notifications-with-amazon-eventbridge. When set, the module creates an EventBridge rule that forwards new objects to the collector Lambda. The bucket is NOT created or modified by this module. Must be a static string known at plan time, and must differ from iam_activity_bucket_name."
  type        = string
  default     = null
  validation {
    condition     = var.alb_access_logs_bucket_name == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.alb_access_logs_bucket_name))
    error_message = "alb_access_logs_bucket_name must be a valid S3 bucket name (3-63 chars, lowercase letters, numbers, dots, hyphens)."
  }
}

variable "alb_access_logs_key_prefix" {
  description = "(Optional) S3 key prefix of the ALB access log objects (the prefix configured on the load balancer's access_logs attribute). When set, the EventBridge rule only matches objects under this prefix and the Lambda's s3:GetObject permission is scoped to it."
  type        = string
  default     = null
}

variable "alb_access_logs_kms_key_arn" {
  description = "(Optional) ARN of the KMS key used to encrypt objects in the ALB access logs bucket (SSE-KMS). When set, the Lambda execution role is granted kms:Decrypt on this key."
  type        = string
  default     = null
}

################################################################################
# General
################################################################################

variable "tags" {
  description = "A map of global tags to add to all created resources"
  type        = map(string)
  default     = {}
}
