data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "streamsec_aws_account" "this" {
  cloud_account_id = data.aws_caller_identity.current.account_id
}

locals {
  runbook_config = yamldecode(file("${path.module}/templates/runbook_config.yaml"))
}

# Generate random external ID
resource "random_string" "external_id" {
  length  = 8
  upper   = true
  numeric = true
  special = false
}

# IAM role for response
resource "aws_iam_role" "response" {
  name = var.response_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.streamsec_account}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = random_string.external_id.result
          }
        }
      }
    ]
  })

  tags = var.tags
}

# IAM policy for response role
resource "aws_iam_role_policy" "response" {
  name = var.response_policy_name
  role = aws_iam_role.response.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:StartAutomationExecution",
          "ssm:GetAutomationExecution",
          "ssm:DescribeAutomationExecutions",
          "ssm:DescribeAutomationStepExecutions"
        ]
        Resource = flatten([
          for response in local.runbook_config.Remediations :
          response.runbook_owner == "AWS" ?
          [
            "arn:aws:ssm:*:*:document/${response.name}",
            "arn:aws:ssm:*:*:automation-definition/${response.name}*"
          ] :
          [
            "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:document/${response.name}",
            "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:automation-definition/${response.name}*"
          ]
        ])
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "*"
      }
    ]
  })
}

# SSM Documents for each response
resource "aws_ssm_document" "response" {
  for_each = { for response in local.runbook_config.Remediations : response.name => response if response.runbook_owner == "StreamSecurity" }

  name            = "${var.runbooks_prefix}${each.value.name}"
  document_type   = "Automation"
  document_format = "YAML"
  content         = file("${path.module}/templates/runbooks/${each.value.name}.yaml")

  tags = var.tags
}

# IAM roles for each response policy
resource "aws_iam_role" "response_roles" {
  for_each = { for response in local.runbook_config.Remediations : response.name => response if response.runbook_owner == "StreamSecurity" }

  name = "${replace(each.value.name, "-", "")}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ssm.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

# IAM policies for each response role
resource "aws_iam_role_policy" "response_policies" {
  for_each = { for response in local.runbook_config.Remediations : response.name => response if response.runbook_owner == "StreamSecurity" }

  name = "${replace(each.value.name, "-", "")}-policy"
  role = aws_iam_role.response_roles[each.key].id

  policy = file("${path.module}/templates/policies/${each.value.policy_file_name}")
}

resource "streamsec_aws_response_ack" "this" {
  cloud_account_id  = data.streamsec_aws_account.this.cloud_account_id
  runbook_role_list = [for role in aws_iam_role.response_roles : role.arn]
  region            = data.aws_region.current.name
  policy_to_role_map = {
    for response in local.runbook_config.Remediations : response.policy_file_name => aws_iam_role.response_roles[response.name].arn
    if response.runbook_owner == "StreamSecurity"
  }
  role_arn     = aws_iam_role.response.arn
  runbook_list = [for doc in aws_ssm_document.response : doc.name]
  external_id  = random_string.external_id.result
  depends_on   = [aws_iam_role.response_roles, aws_iam_role_policy.response_policies, aws_iam_role_policy.response]
}
