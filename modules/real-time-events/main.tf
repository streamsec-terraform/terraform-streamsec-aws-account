data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "streamsec_host" "this" {}
data "streamsec_aws_account" "this" {
  cloud_account_id = data.aws_caller_identity.current.account_id
}

locals {
  lambda_source_code_bucket = "${var.lambda_source_code_bucket_prefix}-${data.aws_region.current.region}"
  cloudwatch_rules = { for i in range(length(fileset(path.module, "templates/*.json"))) :
    "streamsec-rule-${i}" => {
      name          = "${var.cloudwatch_event_rules_prefix}rule-${i}"
      description   = "Cloud Trail for Stream Security real time events Lambda"
      event_pattern = file("${path.module}/templates/CloudWatchEventRule${i}.json")
    }
  }

  compatible_runtimes = [var.lambda_runtime]

  # Use the privatelink endpoint if available, otherwise null
  pl_dns_name = module.privatelink.streamsec_endpoint

  # Final API URL: use PrivateLink only when enabled *and* we have a DNS name
  effective_api_url = (
    var.enable_privatelink && local.pl_dns_name != null
  ) ? "https://${local.pl_dns_name}" : data.streamsec_host.this.url

}

################################################################################
# Real Time Events Lambda
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
        Resource = "arn:aws:secretsmanager:*:${data.aws_caller_identity.current.account_id}:secret:${var.lambda_collection_secret_name}*"
      }
    ]

  })

  tags = merge(var.tags, var.iam_policy_tags)
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution_role_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_execution_role.name
}

resource "aws_iam_role_policy_attachment" "lambda_exec_policy_attachment" {
  policy_arn = aws_iam_policy.lambda_exec_policy.arn
  role       = aws_iam_role.lambda_execution_role.name
}

resource "aws_secretsmanager_secret" "streamsec_collection_secret" {
  name                    = var.lambda_collection_secret_name
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


resource "aws_lambda_function" "streamsec_real_time_events_lambda" {
  function_name = var.lambda_name
  role          = aws_iam_role.lambda_execution_role.arn
  handler       = "src/handler.cloudWatchCollector"
  runtime       = var.lambda_runtime
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
    variables = merge(
      {
        SECRET_NAME = aws_secretsmanager_secret.streamsec_collection_secret.name
        API_URL     = local.effective_api_url
        ENV         = "production"
        NODE_ENV    = "production"
      },
      var.central_vpc_flow_logs_fields != "" ? { DEFAULT_FLOW_LOG_FIELDS = var.central_vpc_flow_logs_fields } : {}
    )
  }

  tags = merge(var.tags, var.lambda_tags)
}

resource "aws_lambda_function_event_invoke_config" "streamsec_options_cloudwatch" {
  function_name                = aws_lambda_function.streamsec_real_time_events_lambda.function_name
  maximum_event_age_in_seconds = var.lambda_cloudwatch_max_event_age
  maximum_retry_attempts       = var.lambda_cloudwatch_max_retry
}

################################################################################
# Real Time Events CloudWatch
################################################################################

resource "aws_cloudwatch_event_rule" "streamsec_cloudwatch_rules" {
  for_each       = local.cloudwatch_rules
  name           = each.value["name"]
  description    = each.value["description"]
  event_pattern  = each.value["event_pattern"]
  tags           = var.tags
}

# Allow time for EventBridge rules to propagate before creating targets
resource "time_sleep" "wait_for_rules" {
  depends_on      = [aws_cloudwatch_event_rule.streamsec_cloudwatch_rules]
  create_duration = "10s"
}

resource "aws_cloudwatch_event_target" "streamsec_lambda_cloudwatch_target" {
  for_each       = local.cloudwatch_rules
  rule           = aws_cloudwatch_event_rule.streamsec_cloudwatch_rules[each.key].name
  target_id      = "CloudWatchToLambda"
  arn            = aws_lambda_function.streamsec_real_time_events_lambda.arn

  depends_on = [time_sleep.wait_for_rules]
}

resource "aws_lambda_permission" "streamsec_allow_lambda_cloudwatch_invocation" {
  for_each      = local.cloudwatch_rules
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.streamsec_real_time_events_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.streamsec_cloudwatch_rules[each.key].arn
}


resource "streamsec_aws_real_time_events_ack" "this" {
  cloud_account_id = data.aws_caller_identity.current.account_id
  region           = data.aws_region.current.region
  depends_on       = [aws_lambda_permission.streamsec_allow_lambda_cloudwatch_invocation]
}

################################################################################
# Private Link
################################################################################
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  count      = var.enable_privatelink ? 1 : 0
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

################################################################################
# Centralized CloudWatch Logs Collection
################################################################################

locals {
  central_log_groups = {
    cloudtrail = var.central_cloudtrail_log_group
    flowlogs   = var.central_vpc_flow_logs_log_group
    eksaudit   = var.central_eks_audit_log_group
    route53    = var.central_route53_log_group
    bedrock    = var.central_bedrock_log_group
  }
  active_central_log_groups = { for k, v in local.central_log_groups : k => v if v != "" }

  eks_audit_filter_pattern = <<-EOT
{(($.sourceIPs[0] != "::1" && $.sourceIPs[0] != "127.0.0.1") || ($.sourceIPs[1] != "::1" && $.sourceIPs[1] != "127.0.0.1")) && $.stage = "ResponseComplete" && $.verb != "watch" && $.user.username != "system:kube*" && $.user.username != "eks:*" && ($.objectRef.resource not exists || ($.objectRef.resource != "events" && $.objectRef.resource != "leases")) && ($.objectRef.subresource not exists || ($.objectRef.subresource != "status" && $.objectRef.subresource != "scale" && $.objectRef.subresource != "proxy" && $.objectRef.subresource != "token" && ($.objectRef.subresource != "binding" || ($.objectRef.subresource = "binding" && $.responseStatus.code != 201))))}
EOT
}

resource "aws_lambda_permission" "streamsec_allow_cwlogs_invocation" {
  count         = length(local.active_central_log_groups) > 0 ? 1 : 0
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.streamsec_real_time_events_lambda.function_name
  principal     = "logs.${data.aws_region.current.name}.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_cloudwatch_log_subscription_filter" "streamsec_central_log_filters" {
  for_each        = local.active_central_log_groups
  name            = "streamsec-${each.key}-to-collector"
  log_group_name  = each.value
  filter_pattern  = each.key == "eksaudit" ? trimspace(local.eks_audit_filter_pattern) : ""
  destination_arn = aws_lambda_function.streamsec_real_time_events_lambda.arn

  depends_on = [aws_lambda_permission.streamsec_allow_cwlogs_invocation]
}

################################################################################
# Centralized Kinesis Integration
################################################################################

resource "aws_iam_policy" "kinesis_read_policy" {
  count       = var.central_kinesis_stream_arn != "" ? 1 : 0
  name        = "${var.lambda_name}-kinesis-read"
  description = "Allow collector Lambda to read from Kinesis stream"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:DescribeStream",
          "kinesis:DescribeStreamSummary",
          "kinesis:ListShards",
          "kinesis:ListStreams"
        ]
        Resource = var.central_kinesis_stream_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "kinesis_read_attachment" {
  count      = var.central_kinesis_stream_arn != "" ? 1 : 0
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = aws_iam_policy.kinesis_read_policy[0].arn
}

resource "aws_lambda_event_source_mapping" "kinesis_to_lambda" {
  count                              = var.central_kinesis_stream_arn != "" ? 1 : 0
  event_source_arn                   = var.central_kinesis_stream_arn
  function_name                      = aws_lambda_function.streamsec_real_time_events_lambda.arn
  starting_position                  = "LATEST"
  batch_size                         = var.central_kinesis_batch_size
  maximum_batching_window_in_seconds = var.central_kinesis_batch_window
  bisect_batch_on_function_error     = true
  maximum_retry_attempts             = 3

  depends_on = [aws_iam_role_policy_attachment.kinesis_read_attachment]
}
