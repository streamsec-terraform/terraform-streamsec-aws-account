locals {
  # Split per workload kind so workload_kinds = "ecs" does not also grant
  # account-wide Lambda read access, and vice versa. Only ECR is shared.
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
      # Layers are deliberately not account-scoped: AWS-published and org-shared
      # layers live elsewhere and their own resource policy authorises the read.
      Resource = [
        "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:*",
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

  # kms:ViaService is ec2.<region> only, matching the CloudFormation template.
  # aws-cn service principals end .amazonaws.com.cn.
  kms_endpoint_suffix = local.partition == "aws-cn" ? "amazonaws.com.cn" : "amazonaws.com"

  kms_via_services = ["ec2.${local.region}.${local.kms_endpoint_suffix}"]

  # Only needed for customer-managed CMKs, whose key policy delegates to IAM;
  # the aws/ebs key grants account principals directly. Missing, scans find zero.
  kms_statements = [
    {
      Sid      = "ReadEncryptedVolumes"
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:DescribeKey"]
      Resource = var.kms_key_arns
      Condition = {
        StringEquals = { "kms:ViaService" = local.kms_via_services }
      }
    },
  ]

  # Shared by all three launchers (orchestrator, EventBridge, initial scan) so
  # they stay in lockstep. RunTask is not: they pass different ARN forms.
  pass_scanner_roles_statement = [
    {
      Sid    = "PassScannerRoles"
      Effect = "Allow"
      Action = "iam:PassRole"
      Resource = [
        aws_iam_role.task.arn,
        aws_iam_role.execution.arn,
      ]
      # The task role holds this grant itself: without the condition, code
      # execution in the container could pass these roles to any service.
      Condition = {
        StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
      }
    },
  ]

  # EventBridge and the initial-scan Lambda are each configured with one exact
  # revision ARN and launch nothing else.
  run_pinned_task_statement = [
    {
      Sid       = "RunScannerTask"
      Effect    = "Allow"
      Action    = "ecs:RunTask"
      Resource  = [aws_ecs_task_definition.this.arn]
      Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
    },
  ]

  # The orchestrator is authorized for the revision-LESS family ARN because that
  # is the form main.tf hands it and the form it passes to RunTask.
  run_family_task_statement = [
    {
      Sid       = "RunScannerTask"
      Effect    = "Allow"
      Action    = "ecs:RunTask"
      Resource  = local.run_task_resources
      Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
    },
  ]

  workload_statements = concat(
    # Filtered with a `for` rather than a ternary: a ternary's arms must unify to
    # one type, and an empty tuple cannot unify with a tuple of statements.
    [for statement in local.workload_lambda_statements : statement if local.scan_lambda_workloads],
    [for statement in local.workload_ecs_statements : statement if local.scan_ecs_workloads],
    [for statement in local.workload_image_statements : statement if local.scan_workloads],
  )
}

################################################################################
# Scanner Task Role
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
        # SourceAccount closes the cross-account confused-deputy case; ECS does
        # not expose a narrower aws:SourceArn at AssumeRole time.
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account_id }
        }
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
      # Describe* cannot be resource-scoped in IAM; read-only metadata only.
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
      # CreateSnapshot is evaluated against both the volume and the new snapshot,
      # and aws:RequestTag/* matches only the snapshot side — keep them split.
      {
        Sid      = "CreateSnapshotOnVolume"
        Effect   = "Allow"
        Action   = "ec2:CreateSnapshot"
        Resource = "arn:${local.partition}:ec2:${local.region}:${local.account_id}:volume/*"
      },
      # The snapshot ARN account field is deliberately EMPTY — pinning it fails
      # every scan with UnauthorizedOperation.
      {
        Sid      = "CreateTaggedSnapshot"
        Effect   = "Allow"
        Action   = "ec2:CreateSnapshot"
        Resource = "arn:${local.partition}:ec2:${local.region}::snapshot/*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/Purpose" = "ebs-package-collector"
          }
        }
      },
      {
        Sid      = "TagSnapshotsAtCreate"
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "arn:${local.partition}:ec2:${local.region}::snapshot/*"
        Condition = {
          StringEquals = { "ec2:CreateAction" = "CreateSnapshot" }
        }
      },
      {
        Sid    = "ReadAndDeleteOwnSnapshots"
        Effect = "Allow"
        Action = [
          "ec2:DeleteSnapshot",
          "ebs:ListSnapshotBlocks",
          "ebs:GetSnapshotBlock",
        ]
        Resource = "arn:${local.partition}:ec2:${local.region}::snapshot/*"
        Condition = {
          StringEquals = { "aws:ResourceTag/Purpose" = "ebs-package-collector" }
        }
      },
      ],
      # Per-kind workload scanning; workload_kinds = "" detaches it entirely.
      local.workload_statements,
      [for statement in local.kms_statements : statement if var.scan_encrypted_volumes],
    )
  })
}

# Kept out of the task role's inline policy to avoid a dependency cycle: the role
# would reference the task definition that already references it. Both the
# orchestrator and worker tasks run as this role.
resource "aws_iam_role_policy" "orchestrator" {
  name = "OrchestratorFanOut"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.run_family_task_statement, local.pass_scanner_roles_statement, [
      {
        Sid       = "OrchestratorDescribeTasks"
        Effect    = "Allow"
        Action    = "ecs:DescribeTasks"
        Resource  = "*"
        Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
      },
    ])
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
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account_id }
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS resolves the task definition's `secrets` block with the EXECUTION role,
# not the task role.
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
        # Without this, any rule in the account could assume the role.
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account_id }
          ArnEquals    = { "aws:SourceArn" = aws_cloudwatch_event_rule.daily.arn }
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "events" {
  name = "RunScannerTask"
  role = aws_iam_role.events.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(local.run_pinned_task_statement, local.pass_scanner_roles_statement)
  })
}

################################################################################
# Initial Scan Lambda Role
################################################################################

resource "aws_iam_role" "initial_scan" {
  count = var.trigger_initial_scan ? 1 : 0

  name = "${local.regional_name}-init-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account_id }
          ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:*" }
        }
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
    Statement = concat(local.run_pinned_task_statement, local.pass_scanner_roles_statement, [
      {
        # Backs the guard against starting a second orchestrator.
        Sid       = "InitialScanCheckForRunningScan"
        Effect    = "Allow"
        Action    = "ecs:ListTasks"
        Resource  = "*"
        Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
      },
    ])
  })
}
