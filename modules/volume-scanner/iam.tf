locals {
  # All read-only. List/Describe/GetAuthorizationToken are account-level actions
  # that cannot be resource-scoped; the per-resource get/pull actions are scoped
  # to their resource ARNs.
  #
  # Split per kind rather than granted as one block, so workload_kinds = "ecs"
  # does not hand the role account-wide Lambda read access (function code is
  # downloadable through lambda:GetFunction) and workload_kinds = "lambda" does
  # not hand it account-wide ECS task/task-definition read access. Only the ECR
  # statements are shared: both kinds pull container images.
  workload_lambda_statements = [
    {
      Sid      = "WorkloadLambdaList"
      Effect   = "Allow"
      Action   = ["lambda:ListFunctions"]
      Resource = "*"
    },
    {
      Sid    = "WorkloadLambdaGet"
      Effect = "Allow"
      Action = [
        "lambda:GetFunction",
        "lambda:GetLayerVersion",
      ]
      Resource = [
        "arn:${local.partition}:lambda:*:*:function:*",
        "arn:${local.partition}:lambda:*:*:layer:*:*",
      ]
    },
  ]

  workload_ecs_statements = [
    {
      Sid    = "WorkloadEcsDiscovery"
      Effect = "Allow"
      Action = [
        "ecs:ListClusters",
        "ecs:ListTasks",
        "ecs:DescribeTasks",
        "ecs:DescribeTaskDefinition",
      ]
      Resource = "*"
    },
  ]

  # Needed by both kinds: Lambda functions can be container images, and Fargate
  # task images live in ECR.
  workload_image_statements = [
    {
      Sid      = "WorkloadImageAuth"
      Effect   = "Allow"
      Action   = ["ecr:GetAuthorizationToken"]
      Resource = "*"
    },
    {
      Sid    = "WorkloadImagePull"
      Effect = "Allow"
      Action = [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
      ]
      Resource = "arn:${local.partition}:ecr:*:*:repository/*"
    },
  ]

  # EBS encryption. Needed for volumes encrypted with a CUSTOMER-MANAGED CMK,
  # whose default key policy contains only "Enable IAM User Permissions" and so
  # delegates authorisation to IAM: the EBS direct API then requires the caller's
  # identity policy to allow the key as well.
  #
  # NOT needed for the AWS-managed aws/ebs key, which grants account principals
  # directly in its own key policy. Verified by experiment in 014466394144: with
  # these statements removed, an aws/ebs-encrypted instance scanned fine while a
  # CMK-encrypted one failed with
  #   ListSnapshotBlocks ... ResourceNotFoundException: KMS key not found
  # (KMS reports authorisation failures as not-found). Restoring them made the
  # same instance scan 701 packages.
  #
  # The failure is silent end to end: the task exits, apply reports success, the
  # console shows the region healthy, and the customer sees zero findings for
  # every CMK-encrypted instance.
  #
  # Actions per
  # https://docs.aws.amazon.com/ebs/latest/userguide/ebs-encryption-requirements.html:
  #   Decrypt / DescribeKey              - read blocks out of an encrypted snapshot
  #   GenerateDataKeyWithoutPlaintext,
  #   ReEncryptFrom / ReEncryptTo,
  #   CreateGrant                        - ec2:CreateSnapshot of an encrypted volume
  #
  # Resource defaults to "*" because customer CMK ARNs are not knowable at plan
  # time; kms_key_arns narrows it for operators who can enumerate their keys.
  # CreateGrant is split out and conditioned on kms:GrantIsForAWSResource, the
  # least-privilege pattern AWS documents, so the role cannot mint grants of its
  # own — only ones EC2 creates on its behalf.
  kms_statements = [
    {
      Sid    = "ReadEncryptedVolumes"
      Effect = "Allow"
      Action = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKeyWithoutPlaintext",
        "kms:ReEncryptFrom",
        "kms:ReEncryptTo",
      ]
      Resource = var.kms_key_arns
    },
    {
      Sid       = "GrantEC2SnapshotAccessToKeys"
      Effect    = "Allow"
      Action    = "kms:CreateGrant"
      Resource  = var.kms_key_arns
      Condition = { Bool = { "kms:GrantIsForAWSResource" = "true" } }
    },
  ]

  workload_statements = concat(
    # Filtered with a `for` rather than a conditional: the two arms of a ternary
    # must unify to one type, and an empty tuple cannot unify with a tuple of
    # statement objects.
    [for statement in local.workload_lambda_statements : statement if local.scan_lambda_workloads],
    [for statement in local.workload_ecs_statements : statement if local.scan_ecs_workloads],
    [for statement in local.workload_image_statements : statement if local.scan_workloads],
  )
}

################################################################################
# Scanner Task Role
#
# IAM is a global namespace, so every role name carries the region — the
# CloudFormation stack relies on CloudFormation auto-naming, which Terraform
# does not have, and two regions in one account would otherwise collide.
################################################################################

resource "aws_iam_role" "task" {
  name = "${local.regional_name}-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "task" {
  name = "EBSScannerPolicy"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      # Describe* operations cannot be resource-scoped in IAM — they list across
      # the account by design. Limited blast radius: read-only metadata, no
      # customer data contents.
      {
        Sid    = "Discover"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeVolumes",
          "ec2:DescribeSnapshots",
        ]
        Resource = "*"
      },
      # CreateSnapshot is evaluated against two resource ARNs in the same call:
      # the source volume AND the new snapshot. The aws:RequestTag/* condition
      # only matches the SNAPSHOT side (it describes tags being applied in the
      # request, which target the snapshot via TagSpecifications). Putting the
      # condition on the volume ARN denies the call with "no identity-based
      # policy allows the action". Keep these two statements split — this is the
      # AWS-recommended pattern for tag-required-on-create.
      {
        Sid      = "CreateSnapshotOnVolume"
        Effect   = "Allow"
        Action   = "ec2:CreateSnapshot"
        Resource = "arn:${local.partition}:ec2:*:*:volume/*"
      },
      {
        Sid      = "CreateTaggedSnapshot"
        Effect   = "Allow"
        Action   = "ec2:CreateSnapshot"
        Resource = "arn:${local.partition}:ec2:*:*:snapshot/*"
        Condition = {
          StringEquals = {
            # The scanner sets this tag on every snapshot it creates, via
            # TagSpecifications on the CreateSnapshot call.
            "aws:RequestTag/Purpose" = "ebs-package-collector"
          }
        }
      },
      # ec2:CreateTags only on snapshots, and only as part of a CreateSnapshot
      # call. Prevents tag tampering on any other resource.
      {
        Sid      = "TagSnapshotsAtCreate"
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "arn:${local.partition}:ec2:*:*:snapshot/*"
        Condition = {
          StringEquals = { "ec2:CreateAction" = "CreateSnapshot" }
        }
      },
      # Delete and read blocks ONLY of snapshots the scanner created. It cannot
      # touch snapshots created by the customer or any other tool.
      {
        Sid    = "ReadAndDeleteOwnSnapshots"
        Effect = "Allow"
        Action = [
          "ec2:DeleteSnapshot",
          "ebs:ListSnapshotBlocks",
          "ebs:GetSnapshotBlock",
        ]
        Resource = "arn:${local.partition}:ec2:*:*:snapshot/*"
        Condition = {
          StringEquals = { "aws:ResourceTag/Purpose" = "ebs-package-collector" }
        }
      },
      ],
      # Workload scanning, granted per kind (see the locals at the top of this
      # file). workload_kinds = "" is documented as disabling workload scanning
      # entirely, and leaving these attached would keep account-wide Lambda, ECS
      # and ECR read access on the role that an IAM/CSPM review — or anything
      # with code execution in the scanner container — could still use.
      local.workload_statements,
      [for statement in local.kms_statements : statement if var.scan_encrypted_volumes],
    )
  })
}

# Orchestrator fan-out permissions live in their own policy rather than inline on
# the task role. Inlining them would create a dependency cycle: the role would
# reference the task definition while the task definition already references the
# role, and iam:PassRole for the role's own ARN would self-cycle. This is the
# same reason the CloudFormation template lifts them into a standalone
# AWS::IAM::Policy — the cycle exists in Terraform's graph too.
#
# Both orchestrator and worker tasks run as this role; the worker simply never
# exercises these actions.
resource "aws_iam_role_policy" "orchestrator" {
  name = "OrchestratorFanOut"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "OrchestratorRunChildTasks"
        Effect    = "Allow"
        Action    = "ecs:RunTask"
        Resource  = local.run_task_resources
        Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
      },
      {
        Sid       = "OrchestratorDescribeTasks"
        Effect    = "Allow"
        Action    = "ecs:DescribeTasks"
        Resource  = "*"
        Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
      },
      {
        Sid    = "OrchestratorPassRoleToChildren"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          aws_iam_role.execution.arn,
          aws_iam_role.task.arn,
        ]
      },
    ]
  })
}

################################################################################
# Scanner Execution Role — pulls the image and writes container logs
################################################################################

resource "aws_iam_role" "execution" {
  name = "${local.regional_name}-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS resolves the task definition's `secrets` block using the EXECUTION role,
# not the task role, and injects the value as an environment variable inside the
# container. Scoped to this module's own secret.
resource "aws_iam_role_policy" "execution_secrets" {
  name = "ReadCollectionToken"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.collection_token.arn
      },
    ]
  })
}

################################################################################
# EventBridge Role — lets the daily rule launch the scanner task
################################################################################

resource "aws_iam_role" "events" {
  name = "${local.regional_name}-events-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "events" {
  name = "RunScannerTask"
  role = aws_iam_role.events.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "ecs:RunTask"
        Resource  = local.run_task_resources
        Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
      },
      {
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          aws_iam_role.task.arn,
          aws_iam_role.execution.arn,
        ]
      },
    ]
  })
}

################################################################################
# Initial Scan Lambda Role
################################################################################

resource "aws_iam_role" "initial_scan" {
  count = var.trigger_initial_scan ? 1 : 0

  name = "${local.regional_name}-initial-scan-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "initial_scan_basic" {
  count = var.trigger_initial_scan ? 1 : 0

  role       = aws_iam_role.initial_scan[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "initial_scan" {
  count = var.trigger_initial_scan ? 1 : 0

  name = "RunInitialScan"
  role = aws_iam_role.initial_scan[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "ecs:RunTask"
        Resource  = local.run_task_resources
        Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
      },
      {
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          aws_iam_role.task.arn,
          aws_iam_role.execution.arn,
        ]
      },
    ]
  })
}
