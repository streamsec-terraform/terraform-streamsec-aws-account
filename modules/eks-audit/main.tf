data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "streamsec_host" "this" {}
data "streamsec_aws_account" "this" {
  cloud_account_id = data.aws_caller_identity.current.account_id
}

data "aws_eks_clusters" "this" {}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  name_prefix = var.resource_prefix != "" ? "${var.resource_prefix}-StreamSecurity" : "StreamSecurity"

  discovered_clusters = data.aws_eks_clusters.this.names

  included_clusters = length(var.eks_include_clusters) > 0 ? (
    [for c in local.discovered_clusters : c if contains(var.eks_include_clusters, c)]
  ) : local.discovered_clusters

  target_clusters = [for c in local.included_clusters : c if !contains(var.eks_exclude_clusters, c)]

  cluster_log_groups = {
    for c in local.target_clusters : c => "/aws/eks/${c}/cluster"
  }

  create_role = var.collector_role_arn == null
  role_arn    = local.create_role ? aws_iam_role.collector[0].arn : var.collector_role_arn

  eks_audit_filter_pattern = <<-EOT
{(($.sourceIPs[0] != "::1" && $.sourceIPs[0] != "127.0.0.1") || ($.sourceIPs[1] != "::1" && $.sourceIPs[1] != "127.0.0.1")) && $.stage = "ResponseComplete" && $.verb != "watch" && $.user.username != "system:kube*" && $.user.username != "eks:*" && ($.objectRef.resource not exists || ($.objectRef.resource != "events" && $.objectRef.resource != "leases")) && ($.objectRef.subresource not exists || ($.objectRef.subresource != "status" && $.objectRef.subresource != "scale" && $.objectRef.subresource != "proxy" && $.objectRef.subresource != "token" && ($.objectRef.subresource != "binding" || ($.objectRef.subresource = "binding" && $.responseStatus.code != 201))))}
EOT
}

################################################################################
# IAM Role (conditional)
################################################################################

resource "aws_iam_role" "collector" {
  count = local.create_role ? 1 : 0

  name = "${local.name_prefix}-eks-audit-collector-role-${random_string.suffix.result}"

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

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  count = local.create_role ? 1 : 0

  role       = aws_iam_role.collector[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "secrets_access" {
  name = "${local.name_prefix}-eks-audit-secrets-policy-${random_string.suffix.result}"
  role = local.create_role ? aws_iam_role.collector[0].id : element(split("/", var.collector_role_arn), length(split("/", var.collector_role_arn)) - 1)

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = aws_secretsmanager_secret.collection_token.arn
      }
    ]
  })
}

################################################################################
# Secrets Manager
################################################################################

resource "aws_secretsmanager_secret" "collection_token" {
  name                    = "${var.collection_token_secret_name}-${random_string.suffix.result}"
  description             = "Stream Security EKS audit collection token"
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "collection_token" {
  secret_id     = aws_secretsmanager_secret.collection_token.id
  secret_string = data.streamsec_aws_account.this.streamsec_collection_token
}

################################################################################
# Lambda Function
################################################################################

data "archive_file" "collector" {
  type        = "zip"
  source_file = "${path.module}/lambda/index.py"
  output_path = "${path.module}/lambda/index.zip"
}

resource "aws_cloudwatch_log_group" "collector" {
  name              = "/aws/lambda/${local.name_prefix}-eks-audit-collector-${random_string.suffix.result}"
  retention_in_days = var.lambda_log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "collector" {
  function_name = "${local.name_prefix}-eks-audit-collector-${random_string.suffix.result}"
  role          = local.role_arn
  handler       = "index.handler"
  runtime       = "python3.13"
  memory_size   = var.collector_lambda_memory_size
  timeout       = var.collector_lambda_timeout

  filename         = data.archive_file.collector.output_path
  source_code_hash = data.archive_file.collector.output_base64sha256

  environment {
    variables = {
      FORWARD_URL = data.streamsec_host.this.url
      SECRET_NAME = aws_secretsmanager_secret.collection_token.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.collector]

  tags = var.tags
}

################################################################################
# CloudWatch Log Subscription Filters
################################################################################

resource "aws_lambda_permission" "allow_cloudwatch_logs" {
  statement_id  = "AllowEKSAuditCWLogs-${random_string.suffix.result}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.collector.arn
  principal     = "logs.amazonaws.com"
  source_arn    = "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/*/cluster"
}

resource "aws_cloudwatch_log_subscription_filter" "eks_audit" {
  for_each = local.cluster_log_groups

  name            = "${local.name_prefix}_eks_cw_rule_${each.key}_${random_string.suffix.result}"
  log_group_name  = each.value
  filter_pattern  = trimspace(local.eks_audit_filter_pattern)
  destination_arn = aws_lambda_function.collector.arn

  depends_on = [aws_lambda_permission.allow_cloudwatch_logs]
}
