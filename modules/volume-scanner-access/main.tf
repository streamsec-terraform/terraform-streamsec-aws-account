data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# The hub's AWS account, its external id and the role names its scanner runs as.
data "streamsec_aws_scanner_hub_access" "this" {
  hub_account_id = local.hub_account_id
}

locals {
  hub_account_id = trimspace(var.hub_account_id)
  partition      = data.aws_partition.current.partition
  hub            = data.streamsec_aws_scanner_hub_access.this

  # What the hub's AssumeSpokeAccessRoles grant names, in every account.
  role_name = "StreamScannerSpokeRole"

  # aws-cn service endpoints end .amazonaws.com.cn.
  endpoint_suffix = local.partition == "aws-cn" ? "amazonaws.com.cn" : "amazonaws.com"
}

resource "aws_iam_role" "this" {
  name                 = local.role_name
  description          = "Lets the Stream Security scanner in the hub account scan this account."
  max_session_duration = 3600

  # The hub account's root plus a role-name filter, not the hub role's ARN: a trust
  # policy stores a named role as its unique id, so a recreated hub role would
  # silently stop matching. One pattern per way the hub's scanner can be deployed.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.hub.hub_cloud_account_id}:root" }
        Action    = "sts:AssumeRole"
        Condition = {
          StringEquals = { "sts:ExternalId" = local.hub.external_id }
          StringLike = {
            "aws:PrincipalArn" = [
              for pattern in local.hub.trusted_role_name_patterns :
              "arn:${local.partition}:iam::${local.hub.hub_cloud_account_id}:role/${pattern}"
            ]
          }
        }
      },
    ]
  })

  tags = merge(var.tags, { "streamsec:component" = "scanner-access" })

  lifecycle {
    precondition {
      condition     = local.hub.role_name == local.role_name
      error_message = "Stream Security names the spoke role \"${local.hub.role_name}\", but the hub's scanner is granted ${local.role_name}. Upgrade this module."
    }

    precondition {
      condition     = length(local.hub.trusted_role_name_patterns) > 0
      error_message = "Stream Security returned no hub role name patterns for hub ${local.hub_account_id}, so the role would trust no scanner."
    }
  }
}

# KEEP IN SYNC with StreamScannerSpokeRole's StreamScannerAccess policy in the console's
# CloudFormation access stack, statement for statement. It is the hub task role's scan grant, widened to every region
# and account; tests/access.tftest.hcl holds the expected copy. The one difference: the
# KMS ViaService suffix follows the partition here.
resource "aws_iam_role_policy" "this" {
  name = "StreamScannerAccess"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Discover"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeVolumes", "ec2:DescribeSnapshots"]
        Resource = "*"
      },
      {
        Sid      = "CreateSnapshotOnVolume"
        Effect   = "Allow"
        Action   = "ec2:CreateSnapshot"
        Resource = "arn:${local.partition}:ec2:*:*:volume/*"
      },
      {
        Sid       = "CreateTaggedSnapshot"
        Effect    = "Allow"
        Action    = "ec2:CreateSnapshot"
        Resource  = "arn:${local.partition}:ec2:*:*:snapshot/*"
        Condition = { StringEquals = { "aws:RequestTag/Purpose" = "ebs-package-collector" } }
      },
      {
        Sid       = "TagSnapshotsAtCreate"
        Effect    = "Allow"
        Action    = ["ec2:CreateTags"]
        Resource  = "arn:${local.partition}:ec2:*:*:snapshot/*"
        Condition = { StringEquals = { "ec2:CreateAction" = "CreateSnapshot" } }
      },
      {
        Sid       = "ReadAndDeleteOwnSnapshots"
        Effect    = "Allow"
        Action    = ["ec2:DeleteSnapshot", "ebs:ListSnapshotBlocks", "ebs:GetSnapshotBlock"]
        Resource  = "arn:${local.partition}:ec2:*:*:snapshot/*"
        Condition = { StringEquals = { "aws:ResourceTag/Purpose" = "ebs-package-collector" } }
      },
      # Every region, so ViaService can't be pinned to one. ec2.*, never ebs.*.
      {
        Sid       = "DecryptEncryptedVolumes"
        Effect    = "Allow"
        Action    = ["kms:Decrypt", "kms:DescribeKey"]
        Resource  = "*"
        Condition = { StringLike = { "kms:ViaService" = "ec2.*.${local.endpoint_suffix}" } }
      },
      {
        Sid      = "WorkloadDiscoveryList"
        Effect   = "Allow"
        Action   = ["lambda:ListFunctions", "ecs:ListClusters", "ecs:ListTasks", "ecs:DescribeTasks", "ecs:DescribeTaskDefinition"]
        Resource = "*"
      },
      {
        Sid    = "WorkloadDiscoveryGet"
        Effect = "Allow"
        Action = ["lambda:GetFunction", "lambda:GetLayerVersion"]
        Resource = [
          "arn:${local.partition}:lambda:*:*:function:*",
          "arn:${local.partition}:lambda:*:*:layer:*:*",
        ]
      },
      {
        Sid      = "WorkloadImageAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid      = "WorkloadImagePull"
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = "arn:${local.partition}:ecr:*:*:repository/*"
      },
    ]
  })
}

# Tells Stream this account's access is in place, and on destroy that it is gone. After
# the role and its policy, so it is created last and destroyed first.
resource "streamsec_aws_scanner_access_ack" "this" {
  hub_account_id         = local.hub_account_id
  spoke_cloud_account_id = data.aws_caller_identity.current.account_id

  depends_on = [
    aws_iam_role.this,
    aws_iam_role_policy.this,
  ]
}
