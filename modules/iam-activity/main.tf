data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "streamsec_host" "this" {}
data "streamsec_aws_account" "this" {
  cloud_account_id = data.aws_caller_identity.current.account_id
}

locals {
  lambda_source_code_bucket = "${var.lambda_source_code_bucket_prefix}-${data.aws_region.current.region}"

  compatible_runtimes = formatlist(var.lambda_runtime)

  apigateway_enabled = var.apigateway_bucket_name != null

  # Additional EXISTING buckets whose new objects are forwarded to the collector
  # Lambda via EventBridge. Each entry becomes a rule/target/permission set and
  # an s3:GetObject grant (scoped to key_prefix when provided).
  # NOTE: every source is declared here even when its bucket_name is null; the
  # collection_buckets local below filters those out. Always consume
  # collection_buckets (not collection_bucket_sources) so disabled sources are
  # never processed.
  collection_bucket_sources = {
    apigateway = {
      bucket_name      = var.apigateway_bucket_name
      key_prefix       = var.apigateway_s3_key_prefix
      kms_key_arn      = var.apigateway_kms_key_arn
      rule_name        = var.apigateway_s3_eventbridge_rule_name
      rule_description = var.apigateway_s3_eventbridge_rule_description
    }
    s3_access_logs = {
      bucket_name      = var.s3_access_logs_bucket_name
      key_prefix       = var.s3_access_logs_key_prefix
      kms_key_arn      = var.s3_access_logs_kms_key_arn
      rule_name        = null
      rule_description = "Stream Security S3 Access Logs S3 EventBridge Rule"
    }
    alb_access_logs = {
      bucket_name      = var.alb_access_logs_bucket_name
      key_prefix       = var.alb_access_logs_key_prefix
      kms_key_arn      = var.alb_access_logs_kms_key_arn
      rule_name        = null
      rule_description = "Stream Security ALB Access Logs S3 EventBridge Rule"
    }
  }

  # Drop sources whose bucket_name is null (feature not enabled for that type).
  collection_buckets = { for k, v in local.collection_bucket_sources : k => v if v.bucket_name != null }

  collection_kms_key_arns = distinct([for v in values(local.collection_buckets) : v.kms_key_arn if v.kms_key_arn != null])

  # Buckets the collector Lambda is allowed to read from: always the IAM activity
  # bucket, plus every connected collection bucket.
  s3_read_resources = concat(
    [
      data.aws_s3_bucket.iam_activity_bucket.arn,
      "${data.aws_s3_bucket.iam_activity_bucket.arn}/*",
    ],
    flatten([
      for k, v in local.collection_buckets : [
        data.aws_s3_bucket.collection_bucket[k].arn,
        "${data.aws_s3_bucket.collection_bucket[k].arn}/${v.key_prefix != null ? v.key_prefix : ""}*",
      ]
    ])
  )
}

################################################################################
# IAM Activity Lambda
################################################################################

resource "aws_iam_role" "lambda_execution_role" {
  name        = var.lambda_iam_role_use_name_prefix ? null : var.lambda_iam_role_name
  name_prefix = var.lambda_iam_role_use_name_prefix ? var.lambda_iam_role_name : null
  path        = var.lambda_iam_role_path
  description = var.lambda_iam_role_description

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
  tags = merge(var.tags, var.lambda_iam_role_tags)
}

resource "aws_iam_policy" "lambda_exec_policy" {
  name        = var.lambda_policy_use_name_prefix ? null : var.lambda_policy_name
  name_prefix = var.lambda_policy_use_name_prefix ? var.lambda_policy_name : null
  description = var.lambda_policy_description
  path        = var.lambda_policy_path

  policy = jsonencode({
    "Version" : "2012-10-17"
    "Statement" : concat(
      [
        {
          Action = [
            "secretsmanager:GetSecretValue"
          ],
          Effect   = "Allow",
          Resource = "arn:aws:secretsmanager:*:${data.aws_caller_identity.current.account_id}:secret:${var.collection_iam_activity_token_secret_name}*"
        },
        # s3 permissions
        {
          Action = [
            "s3:GetObject",
          ],
          Effect   = "Allow",
          Resource = local.s3_read_resources
        },
      ],
      # decrypt SSE-KMS objects in the connected collection buckets
      length(local.collection_kms_key_arns) > 0 ? [
        {
          Action = [
            "kms:Decrypt",
          ],
          Effect   = "Allow",
          Resource = local.collection_kms_key_arns
        },
      ] : []
    )
  })

  tags = merge(var.tags, var.iam_policy_tags)
}

resource "aws_iam_role_policy_attachment" "lambda_execution_role_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_execution_role.name
}

resource "aws_iam_role_policy_attachment" "lambda_exec_policy_attachment" {
  policy_arn = aws_iam_policy.lambda_exec_policy.arn
  role       = aws_iam_role.lambda_execution_role.name
}

resource "aws_secretsmanager_secret" "streamsec_collection_secret" {
  name                    = var.collection_iam_activity_token_secret_name
  description             = "Stream Security Collection Token"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "streamsec_collection_secret_version" {
  secret_id     = aws_secretsmanager_secret.streamsec_collection_secret.id
  secret_string = data.streamsec_aws_account.this.streamsec_collection_token
}


resource "aws_lambda_layer_version" "streamsec_lambda_layer" {
  s3_bucket           = local.lambda_source_code_bucket
  s3_key              = var.lambda_layer_s3_source_code_key
  layer_name          = var.lambda_layer_name
  compatible_runtimes = local.compatible_runtimes
}

resource "aws_lambda_function" "streamsec_iam_activity_lambda" {
  function_name = var.lambda_name
  role          = aws_iam_role.lambda_execution_role.arn
  handler       = "src/handler.s3Collector"
  runtime       = var.lambda_runtime
  memory_size   = var.lambda_cloudwatch_memory_size
  timeout       = var.lambda_cloudwatch_timeout
  s3_bucket     = local.lambda_source_code_bucket
  s3_key        = var.lambda_cloudwatch_s3_source_code_key
  layers        = [aws_lambda_layer_version.streamsec_lambda_layer.arn]

  vpc_config {
    subnet_ids         = var.lambda_subnet_ids
    security_group_ids = var.lambda_security_group_ids
  }

  environment {
    variables = merge(
      {
        API_TOKEN   = var.collection_iam_activity_token_secret_name
        SECRET_NAME = var.collection_iam_activity_token_secret_name
        API_URL     = data.streamsec_host.this.url
        BATCH_SIZE  = var.lambda_batch_size
        ENV         = "production"
        NODE_ENV    = "production"
      },
      # enables API Gateway access-log collection in the collector and tells it
      # how to parse the customer-defined log format
      local.apigateway_enabled ? { API_GATEWAY_LOG_FORMAT = var.apigateway_log_format } : {},
      local.apigateway_enabled && var.apigateway_s3_key_prefix != null ? { API_GATEWAY_S3_KEY_PATTERN = var.apigateway_s3_key_prefix } : {}
    )
  }

  lifecycle {
    precondition {
      condition     = !local.apigateway_enabled || var.apigateway_log_format != null
      error_message = "apigateway_log_format is required when apigateway_bucket_name is set: the collector cannot parse API Gateway access logs without the stage's log format string."
    }
  }

  tags = merge(var.tags, var.lambda_tags)
}

resource "aws_lambda_function_event_invoke_config" "streamsec_options_cloudwatch" {
  function_name                = aws_lambda_function.streamsec_iam_activity_lambda.function_name
  maximum_event_age_in_seconds = var.lambda_cloudwatch_max_event_age
  maximum_retry_attempts       = var.lambda_cloudwatch_max_retry
}

resource "aws_lambda_permission" "streamsec_iam_activity_allow_s3_invoke" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.streamsec_iam_activity_lambda.arn
  principal     = "s3.amazonaws.com"
  source_arn    = data.aws_s3_bucket.iam_activity_bucket.arn
}


################################################################################
# IAM Activity S3
################################################################################

data "aws_s3_bucket" "iam_activity_bucket" {
  bucket = var.iam_activity_bucket_name
}

resource "aws_s3_bucket_notification" "iam_activity_s3_lambda_trigger" {
  count  = var.iam_activity_s3_eventbridge_trigger ? 0 : 1
  bucket = data.aws_s3_bucket.iam_activity_bucket.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.streamsec_iam_activity_lambda.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.streamsec_iam_activity_allow_s3_invoke]
}

moved {
  from = aws_s3_bucket_notification.iam_activity_s3_lambda_trigger
  to   = aws_s3_bucket_notification.iam_activity_s3_lambda_trigger[0]
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  count       = var.iam_activity_s3_eventbridge_trigger ? 1 : 0
  bucket      = data.aws_s3_bucket.iam_activity_bucket.id
  eventbridge = true
}

resource "aws_cloudwatch_event_rule" "iam_activity_s3_eventbridge_trigger" {
  count       = var.iam_activity_s3_eventbridge_trigger ? 1 : 0
  name        = var.iam_activity_s3_eventbridge_rule_name
  description = var.iam_activity_s3_eventbridge_rule_description
  event_pattern = jsonencode({
    source      = ["aws.s3"],
    detail-type = ["Object Created"],
    detail = {
      bucket = {
        name = [var.iam_activity_bucket_name]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "iam_activity_s3_eventbridge_target" {
  count = var.iam_activity_s3_eventbridge_trigger ? 1 : 0
  rule  = aws_cloudwatch_event_rule.iam_activity_s3_eventbridge_trigger[0].name
  arn   = aws_lambda_function.streamsec_iam_activity_lambda.arn
}

resource "aws_lambda_permission" "iam_activity_s3_allow_invoke" {
  count         = var.iam_activity_s3_eventbridge_trigger ? 1 : 0
  statement_id  = "AllowInvocationFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.streamsec_iam_activity_lambda.arn
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.iam_activity_s3_eventbridge_trigger[0].arn
}


################################################################################
# Additional Collection Buckets (existing buckets, EventBridge only)
# API Gateway access logs / S3 access logs / ALB access logs
################################################################################

data "aws_s3_bucket" "collection_bucket" {
  for_each = local.collection_buckets
  bucket   = each.value.bucket_name

  lifecycle {
    precondition {
      condition     = each.value.bucket_name != var.iam_activity_bucket_name
      error_message = "Collection bucket names must differ from iam_activity_bucket_name: two notification/trigger configurations on the same bucket overwrite each other and cause duplicate Lambda invocations."
    }
    precondition {
      condition     = length([for v in values(local.collection_buckets) : v.bucket_name if v.bucket_name == each.value.bucket_name]) == 1
      error_message = "Each collection bucket name must be used by only one source (apigateway / s3_access_logs / alb_access_logs). Two sources on the same bucket create two EventBridge rules whose object-key patterns can overlap, double-invoking the collector Lambda for the same object."
    }
  }
}

# PREREQUISITE: EventBridge notifications must already be enabled on each bucket
# (bucket Properties -> Amazon EventBridge, or eventbridge = true in the stack
# that owns the bucket's notification configuration). The module deliberately
# does not manage the buckets' notification configuration: it is a single
# replace-all document, and overwriting it would destroy any existing
# SQS/SNS/Lambda notifications on these customer-owned buckets.
resource "aws_cloudwatch_event_rule" "collection_bucket_trigger" {
  for_each    = local.collection_buckets
  name        = coalesce(each.value.rule_name, "streamsec-${each.key}-s3-${substr(md5(each.value.bucket_name), 0, 8)}-rule")
  description = each.value.rule_description
  event_pattern = jsonencode({
    source      = ["aws.s3"],
    detail-type = ["Object Created"],
    detail = merge(
      {
        bucket = {
          name = [each.value.bucket_name]
        }
      },
      each.value.key_prefix != null ? {
        object = {
          key = [{ prefix = each.value.key_prefix }]
        }
      } : {}
    )
  })

  tags = var.tags

  lifecycle {
    precondition {
      condition     = data.aws_s3_bucket.collection_bucket[each.key].bucket_region == data.aws_region.current.region
      error_message = "Collection buckets must be in the same region as this module's provider: S3 emits EventBridge events in the bucket's region, so a cross-region rule would never fire."
    }
  }
}

resource "aws_cloudwatch_event_target" "collection_bucket_target" {
  for_each = local.collection_buckets
  rule     = aws_cloudwatch_event_rule.collection_bucket_trigger[each.key].name
  arn      = aws_lambda_function.streamsec_iam_activity_lambda.arn

  depends_on = [aws_lambda_permission.collection_bucket_allow_invoke]
}

resource "aws_lambda_permission" "collection_bucket_allow_invoke" {
  for_each      = local.collection_buckets
  statement_id  = "AllowInvocationFromEventBridge-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.streamsec_iam_activity_lambda.arn
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.collection_bucket_trigger[each.key].arn
}
