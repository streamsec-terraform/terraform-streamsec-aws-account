data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "streamsec_host" "this" {}
data "streamsec_aws_account" "this" {
  cloud_account_id = data.aws_caller_identity.current.account_id
}

locals {
  lambda_source_code_bucket = "${var.lambda_source_code_bucket_prefix}-${data.aws_region.current.name}"

  # If the privatelink module/output is null (e.g., disabled or not yet created), fall back to empty list
  _pl_dns_entries = coalesce(module.privatelink.lightlytics_endpoint, null)

  # Safely pick first dns_name if present; otherwise null
  _pl_dns_name = length(local._pl_dns_entries) > 0 ? module.privatelink.lightlytics_endpoint : null

  # Final API URL: use PrivateLink only when enabled *and* we have a DNS name
  effective_api_url = (
    var.enable_privatelink && local._pl_dns_name != null
  ) ? "https://${local._pl_dns_name}" : data.streamsec_host.this.url
}

################################################################################
# FlowLogs Lambda
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
    "Statement" : [
      {
        Action = [
          "secretsmanager:GetSecretValue"
        ],
        Effect   = "Allow",
        Resource = "arn:aws:secretsmanager:*:${data.aws_caller_identity.current.account_id}:secret:${var.collection_flowlogs_token_secret_name}*"
      },
      # s3 permissions
      {
        Action = [
          "s3:GetObject",
        ],
        Effect = "Allow",
        Resource = [
          data.aws_s3_bucket.flowlogs_bucket.arn,
          "${data.aws_s3_bucket.flowlogs_bucket.arn}/*"
        ]
      },
      {
        Action = [
          "ec2:DescribeFlowLogs",
        ],
        Effect   = "Allow",
        Resource = "*"
      }
    ]

  })
}

resource "aws_iam_role_policy_attachment" "lambda_flowlogs_execution_role_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_execution_role.name
}

resource "aws_iam_role_policy_attachment" "lambda_flowlogs_exec_policy_attachment" {
  policy_arn = aws_iam_policy.lambda_exec_policy.arn
  role       = aws_iam_role.lambda_execution_role.name
}

resource "aws_secretsmanager_secret" "streamsec_collection_secret" {
  name                    = var.collection_flowlogs_token_secret_name
  description             = "Stream Security Collection Token"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "streamsec_collection_secret_version" {
  secret_id     = aws_secretsmanager_secret.streamsec_collection_secret.id
  secret_string = data.streamsec_aws_account.this.streamsec_collection_token
}


resource "aws_lambda_layer_version" "streamsec_lambda_layer" {
  s3_bucket           = local.lambda_source_code_bucket
  s3_key              = var.lambda_layer_s3_source_code_key
  layer_name          = var.lambda_layer_name
  compatible_runtimes = ["nodejs20.x"]
}

resource "aws_lambda_function" "streamsec_flowlogs_lambda" {
  function_name = var.lambda_name
  role          = aws_iam_role.lambda_execution_role.arn
  handler       = "src/handler.s3Collector"
  runtime       = "nodejs20.x"
  memory_size   = var.lambda_cloudwatch_memory_size
  timeout       = var.lambda_cloudwatch_timeout
  s3_bucket     = local.lambda_source_code_bucket
  s3_key        = var.lambda_cloudwatch_s3_source_code_key
  layers        = [aws_lambda_layer_version.streamsec_lambda_layer.arn]

  vpc_config {
    subnet_ids         = var.enable_privatelink && var.private_subnet_ids != null ? var.private_subnet_ids : var.lambda_subnet_ids
    security_group_ids = var.enable_privatelink ? concat(var.lambda_security_group_ids, [module.privatelink.privatelink_security_group_id]) : var.lambda_security_group_ids
  }

  environment {
    variables = {
      API_URL     = local.effective_api_url
      SECRET_NAME = var.collection_flowlogs_token_secret_name
      BATCH_SIZE  = var.lambda_batch_size
      ENV         = "production"
      NODE_ENV    = "production"
    }
  }
}

resource "aws_lambda_function_event_invoke_config" "streamsec_options_cloudwatch" {
  function_name                = aws_lambda_function.streamsec_flowlogs_lambda.function_name
  maximum_event_age_in_seconds = var.lambda_cloudwatch_max_event_age
  maximum_retry_attempts       = var.lambda_cloudwatch_max_retry
}

resource "aws_lambda_permission" "streamsec_flowlogs_allow_s3_invoke" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.streamsec_flowlogs_lambda.arn
  principal     = "s3.amazonaws.com"
  source_arn    = data.aws_s3_bucket.flowlogs_bucket.arn
}


################################################################################
# FlowLogs S3
################################################################################

data "aws_s3_bucket" "flowlogs_bucket" {
  bucket = var.create_flowlogs_bucket ? aws_s3_bucket.streamsec_flowlogs_bucket[0].bucket : var.flowlogs_bucket_name
}

resource "aws_s3_bucket" "streamsec_flowlogs_bucket" {
  count         = var.create_flowlogs_bucket ? 1 : 0
  bucket        = var.flowlogs_bucket_use_name_prefix ? null : var.flowlogs_bucket_name
  bucket_prefix = var.flowlogs_bucket_use_name_prefix ? var.flowlogs_bucket_name : null
  force_destroy = var.flowlogs_bucket_force_destroy

  tags = merge(var.tags, var.flowlogs_bucket_tags)
}

resource "aws_flow_log" "streamsec_flowlogs" {
  count                = var.create_flowlogs_bucket ? length(var.vpc_ids) : 0
  log_destination      = data.aws_s3_bucket.flowlogs_bucket.arn
  log_destination_type = "s3"
  traffic_type         = "ALL"
  vpc_id               = element(tolist(var.vpc_ids), count.index)
  log_format           = "$${version} $${account-id} $${action} $${bytes} $${dstaddr} $${end} $${instance-id} $${interface-id} $${log-status} $${packets} $${pkt-dstaddr} $${pkt-srcaddr} $${protocol} $${region} $${srcaddr} $${srcport} $${dstport} $${start} $${vpc-id} $${subnet-id} $${tcp-flags}"
}

resource "aws_s3_bucket_notification" "flowlogs_s3_lambda_trigger" {
  count  = var.flowlogs_s3_eventbridge_trigger ? 0 : 1
  bucket = data.aws_s3_bucket.flowlogs_bucket.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.streamsec_flowlogs_lambda.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.streamsec_flowlogs_allow_s3_invoke]
}

moved {
  from = aws_s3_bucket_notification.flowlogs_s3_lambda_trigger
  to   = aws_s3_bucket_notification.flowlogs_s3_lambda_trigger[0]
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  count       = var.flowlogs_s3_eventbridge_trigger ? 1 : 0
  bucket      = data.aws_s3_bucket.flowlogs_bucket.id
  eventbridge = true
}

resource "aws_cloudwatch_event_rule" "flowlogs_s3_eventbridge_trigger" {
  count       = var.flowlogs_s3_eventbridge_trigger ? 1 : 0
  name        = var.flowlogs_eventbridge_rule_name
  description = var.flowlogs_eventbridge_rule_description
  event_pattern = jsonencode({
    source      = ["aws.s3"],
    detail-type = ["Object Created"],
    detail = {
      bucket = {
        name = [var.flowlogs_bucket_name]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "flowlogs_s3_eventbridge_target" {
  count = var.flowlogs_s3_eventbridge_trigger ? 1 : 0
  rule  = aws_cloudwatch_event_rule.flowlogs_s3_eventbridge_trigger[0].name
  arn   = aws_lambda_function.streamsec_flowlogs_lambda.arn
}

resource "aws_lambda_permission" "flowlogs_s3_allow_invoke" {
  count         = var.flowlogs_s3_eventbridge_trigger ? 1 : 0
  statement_id  = "AllowInvocationFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.streamsec_flowlogs_lambda.arn
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.flowlogs_s3_eventbridge_trigger[0].arn
}

resource "aws_s3_bucket_lifecycle_configuration" "flowlogs_bucket_config" {
  count  = var.create_flowlogs_bucket ? 1 : 0
  bucket = data.aws_s3_bucket.flowlogs_bucket.id
  rule {
    id = var.flowlogs_bucket_lifecycle_rule[0].id
    expiration {
      days = var.flowlogs_bucket_lifecycle_rule[0].days
    }
    filter {
      prefix = var.flowlogs_bucket_lifecycle_rule[0].prefix
    }
    status = var.flowlogs_bucket_lifecycle_rule[0].status
  }
}

################################################################################
# Private Link
################################################################################
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  count      = var.enable_privatelink ? 1 : 0
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}
