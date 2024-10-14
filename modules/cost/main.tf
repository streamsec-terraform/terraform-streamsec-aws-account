data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "streamsec_host" "this" {}
data "streamsec_aws_account" "this" {
  cloud_account_id = data.aws_caller_identity.current.account_id
}

locals {
  lambda_source_code_bucket = "${var.lambda_source_code_bucket_prefix}-${data.aws_region.current.name}"
}

resource "random_uuid" "external_id" {}

################################################################################
# IAM Role
################################################################################
resource "aws_iam_role" "this" {
  name        = var.iam_role_use_name_prefix ? null : var.iam_role_name
  name_prefix = var.iam_role_use_name_prefix ? var.iam_role_name : null
  path        = var.iam_role_path
  description = var.iam_role_description

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${var.streamsec_account}:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "${random_uuid.external_id.result}"
        }
      }
    }
  ]
}
EOF
  tags               = merge(var.tags, var.iam_role_tags)
}

resource "aws_iam_policy" "streamsec_policy" {

  name        = var.iam_policy_use_name_prefix ? null : var.iam_policy_name
  name_prefix = var.iam_policy_use_name_prefix ? var.iam_policy_name : null
  description = var.iam_policy_description
  path        = var.iam_policy_path

  policy = jsonencode({
    "Version" : "2012-10-17"
    "Statement" : [
      {
        Action = "s3:GetObject"
        Effect = "Allow",
        Resource = [
          "${data.aws_s3_bucket.cost_bucket.arn}/*"
        ]
      }
    ]
  })

  tags = merge(var.tags, var.iam_policy_tags)
}

resource "aws_iam_role_policy_attachment" "streamsec_policy_attachment" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.streamsec_policy.arn
}

################################################################################
# Cost Lambda
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
        Resource = "arn:aws:secretsmanager:*:${data.aws_caller_identity.current.account_id}:secret:${var.collection_cost_token_secret_name}*"
      },
      # s3 permissions
      {
        Action = [
          "s3:GetObject",
        ],
        Effect   = "Allow",
        Resource = "${data.aws_s3_bucket.cost_bucket.arn}/*"
      },
      {
        Action = [
          "s3:ListBucket",
        ],
        Effect   = "Allow",
        Resource = data.aws_s3_bucket.cost_bucket.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_cost_execution_role_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_execution_role.name
}

resource "aws_iam_role_policy_attachment" "lambda_cost_exec_policy_attachment" {
  policy_arn = aws_iam_policy.lambda_exec_policy.arn
  role       = aws_iam_role.lambda_execution_role.name
}

resource "aws_secretsmanager_secret" "streamsec_collection_secret" {
  name                    = var.collection_cost_token_secret_name
  description             = "Stream Security Collection Token"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "streamsec_collection_secret_version" {
  secret_id     = aws_secretsmanager_secret.streamsec_collection_secret.id
  secret_string = data.streamsec_aws_account.this.streamsec_collection_token
}

resource "aws_cloudwatch_log_group" "streamsec_lambda_log_group" {
  name              = "/aws/lambda/${var.lambda_name}"
  retention_in_days = var.lambda_log_group_retention
}

import {
  to = aws_cloudwatch_log_group.streamsec_lambda_log_group
  id = "/aws/lambda/${var.lambda_name}"
}

resource "aws_lambda_function" "streamsec_cost_lambda" {
  function_name = var.lambda_name
  role          = aws_iam_role.lambda_execution_role.arn
  handler       = "src/handler.costCollector"
  runtime       = "nodejs20.x"
  memory_size   = var.lambda_cloudwatch_memory_size
  timeout       = var.lambda_cloudwatch_timeout
  s3_bucket     = local.lambda_source_code_bucket
  s3_key        = var.lambda_cloudwatch_s3_source_code_key

  logging_config {
    log_group  = aws_cloudwatch_log_group.streamsec_lambda_log_group.name
    log_format = "text"
  }

  vpc_config {
    subnet_ids         = var.lambda_subnet_ids
    security_group_ids = var.lambda_security_group_ids
  }

  environment {
    variables = {
      API_URL     = data.streamsec_host.this.url
      SECRET_NAME = var.collection_cost_token_secret_name
      ENV         = "production"
      NODE_ENV    = "production"
    }
  }
}

resource "aws_lambda_function_event_invoke_config" "streamsec_options_cloudwatch" {
  function_name                = aws_lambda_function.streamsec_cost_lambda.function_name
  maximum_event_age_in_seconds = var.lambda_cloudwatch_max_event_age
  maximum_retry_attempts       = var.lambda_cloudwatch_max_retry
}

resource "aws_lambda_permission" "streamsec_cost_allow_s3_invoke" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.streamsec_cost_lambda.arn
  principal     = "s3.amazonaws.com"
  source_arn    = data.aws_s3_bucket.cost_bucket.arn
}


################################################################################
# Cost S3
################################################################################

data "aws_s3_bucket" "cost_bucket" {
  bucket = var.create_cost_bucket ? aws_s3_bucket.streamsec_cost_bucket[0].bucket : var.cost_bucket_name
}

resource "aws_s3_bucket" "streamsec_cost_bucket" {
  count         = var.create_cost_bucket ? 1 : 0
  bucket        = var.cost_bucket_use_name_prefix ? null : var.cost_bucket_name
  bucket_prefix = var.cost_bucket_use_name_prefix ? var.cost_bucket_name : null
  force_destroy = var.cost_bucket_force_destroy

  tags = merge(var.tags, var.cost_bucket_tags)
}

resource "aws_s3_bucket_policy" "s3_cloudtrail_policy_attachment" {
  count  = var.create_cost_bucket ? 1 : 0
  bucket = aws_s3_bucket.streamsec_cost_bucket[0].id
  policy = jsonencode({
    Version = "2008-10-17"
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "billingreports.amazonaws.com"
        },
        Action = [
          "s3:GetBucketAcl",
          "s3:GetBucketPolicy"
        ],
        Resource = aws_s3_bucket.streamsec_cost_bucket[0].arn,
        Condition = {
          StringEquals = {
            "aws:SourceAccount" : data.aws_caller_identity.current.account_id,
            "aws:SourceArn" : "arn:aws:cur:us-east-1:${data.aws_caller_identity.current.account_id}:definition/*"
          }
        }
      },
      {
        Effect = "Allow",
        Principal = {
          Service = "billingreports.amazonaws.com"
        },
        Action = [
          "s3:PutObject"
        ],
        Resource = "${aws_s3_bucket.streamsec_cost_bucket[0].arn}/*",
        Condition = {
          StringEquals = {
            "aws:SourceAccount" : data.aws_caller_identity.current.account_id,
            "aws:SourceArn" : "arn:aws:cur:us-east-1:${data.aws_caller_identity.current.account_id}:definition/*"
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_notification" "cost_s3_lambda_trigger" {
  bucket = data.aws_s3_bucket.cost_bucket.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.streamsec_cost_lambda.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.streamsec_cost_allow_s3_invoke]
}

resource "aws_s3_bucket_lifecycle_configuration" "cost_bucket_config" {
  count  = var.create_cost_bucket ? 1 : 0
  bucket = data.aws_s3_bucket.cost_bucket.id
  rule {
    id = var.cost_bucket_lifecycle_rule[0].id
    expiration {
      days = var.cost_bucket_lifecycle_rule[0].days
    }
    filter {
      prefix = var.cost_bucket_lifecycle_rule[0].prefix
    }
    status = var.cost_bucket_lifecycle_rule[0].status
  }
}

resource "aws_cur_report_definition" "cur_report_definition" {
  count                      = var.create_cost_bucket ? 1 : 0
  report_name                = var.cur_report_name
  time_unit                  = var.cur_time_unit
  format                     = "textORcsv"
  compression                = "GZIP"
  additional_schema_elements = ["RESOURCES"]
  s3_bucket                  = data.aws_s3_bucket.cost_bucket.bucket
  s3_region                  = "us-east-1"
}

resource "streamsec_aws_cost_ack" "this" {
  cloud_account_id = data.aws_caller_identity.current.account_id
  role_arn         = aws_iam_role.this.arn
  external_id      = random_uuid.external_id.result
  bucket_arn       = data.aws_s3_bucket.cost_bucket.arn
  cur_prefix       = var.cur_prefix
  depends_on       = [aws_lambda_permission.streamsec_cost_allow_s3_invoke]
}
