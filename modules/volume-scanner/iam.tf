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
      # Deliberately NOT scoped to this account. An earlier pass pinned these to
      # ${local.account_id}, which broke the two commonest real deployments:
      # AWS-published layers (AWSSDKPandas, LambdaInsights) live in AWS-owned
      # accounts, and enterprises run a central images account whose ECR
      # repository policy allows the org. The layer or image resource policy is
      # what actually authorises the read; pinning the identity policy to this
      # account denied it, so those packages silently never reached the SBOM and
      # the function or task was reported scanned with an incomplete list.
      #
      # This is what the CloudFormation stack grants, and matching it is the
      # point: lambda:*:*:layer:*:* and ecr:*:*:repository/*. These are read-only
      # actions on resources whose owner must independently opt in.
      #
      # NOTE for snapshot ARNs elsewhere in this file: EC2 authorizes snapshot
      # actions against arn:<partition>:ec2:<region>::snapshot/* with an EMPTY
      # account field. Pinning the account there produces
      # "UnauthorizedOperation ... no identity-based policy allows
      # ec2:CreateSnapshot", verified against real AWS. Region-pinning alone is
      # what closes the cross-region hazard.
      Resource = [
        # Functions stay account- and region-scoped: the scanner only ever reads
        # functions in the account and region it runs in.
        "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:*",
        # Layers do not: AWS-published and org-shared layers live elsewhere.
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
  # directly in its own key policy. Verified by experiment: with these statements
  # removed, an aws/ebs-encrypted instance scanned fine while an otherwise
  # identical CMK-encrypted one failed with
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
  #
  # kms:ViaService confines the "*" default to keys used THROUGH the EC2/EBS data
  # plane, so a role that can read encrypted volumes cannot also decrypt S3
  # objects, RDS storage or Secrets Manager values protected by the same CMK.
  #
  # ec2.<region> ONLY, matching the CloudFormation template. This module
  # previously also listed ebs.<region> on the theory that the EBS Direct block
  # reads present as their own service principal. They do not: DEV-21730
  # measured both calls against a real CMK-encrypted snapshot and found
  # kms:DescribeKey -> ebs:ListSnapshotBlocks and kms:Decrypt ->
  # ebs:GetSnapshotBlock BOTH arrive as ec2.<region>. ViaService is a list, so
  # the extra value was an inert widening rather than a bug — but it was
  # unevidenced, and the console stack has run on ec2-only in production.
  #
  # aws-cn service principals end .amazonaws.com.cn. Hardcoding the commercial
  # suffix meant the condition could never match there, implicitly denying
  # kms:Decrypt and silently reporting nothing for every CMK-encrypted volume —
  # the exact failure this condition's own comment warns about.
  kms_endpoint_suffix = local.partition == "aws-cn" ? "amazonaws.com.cn" : "amazonaws.com"

  kms_via_services = ["ec2.${local.region}.${local.kms_endpoint_suffix}"]

  # Exactly the two actions the CloudFormation template grants, and no more.
  # This module previously added kms:GenerateDataKeyWithoutPlaintext,
  # kms:ReEncryptFrom, kms:ReEncryptTo and a whole kms:CreateGrant statement,
  # derived from AWS documentation on snapshot COPY rather than from anything
  # the scanner does. The scanner has no copy or re-encrypt path, and DEV-21730
  # measured ec2:CreateSnapshot needing neither CreateGrant nor
  # GenerateDataKeyWithoutPlaintext. They were pure privilege surface — a
  # mutating grant on every CMK reachable through the EC2 data plane, held by a
  # role that runs third-party container code.
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

  # PassRole is identical for all three launchers (orchestrator, EventBridge,
  # initial scan). They were three near-identical copies, differing only in Sid
  # presence and PassRole ordering — which is how a missing grant hid behind a
  # vacuous test. One definition keeps them in lockstep.
  #
  # RunTask is NOT identical, because the three launchers pass different ARN
  # forms. The CloudFormation template scopes all three to !Ref
  # ScannerTaskDefinition — the pinned revision — and rewrites them on every
  # stack update. Two of the three are matched exactly below; the orchestrator
  # is not, deliberately. See run_task_statement_* .
  pass_scanner_roles_statement = [
    {
      Sid    = "PassScannerRoles"
      Effect = "Allow"
      Action = "iam:PassRole"
      Resource = [
        aws_iam_role.task.arn,
        aws_iam_role.execution.arn,
      ]
      # The scanner task role holds this grant itself, so without the condition
      # anything with code execution in the container could pass these roles to
      # any service that accepts them, not just ECS.
      Condition = {
        StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
      }
    },
  ]

  # EventBridge and the initial-scan Lambda are each configured with one exact
  # revision ARN and launch nothing else, so they get the CloudFormation
  # template's scoping verbatim: that one revision.
  run_pinned_task_statement = [
    {
      Sid       = "RunScannerTask"
      Effect    = "Allow"
      Action    = "ecs:RunTask"
      Resource  = [aws_ecs_task_definition.this.arn]
      Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
    },
  ]

  # The orchestrator is the one launcher that does NOT get the pinned revision.
  # It is handed the revision-LESS family ARN in COLLECTOR_ECS_TASK_DEF_ARN
  # (main.tf, matching the CloudFormation template's own env var) and calls
  # RunTask with that form, so authorizing it against a single revision ARN
  # depends on ECS resolving family -> latest ACTIVE revision before IAM
  # evaluates the request. The console stack relies on exactly that and works in
  # production, but it is an undocumented resolution order to hang the fan-out
  # on: the failure mode is a mid-scan AccessDenied on every child task, after
  # snapshots are already created. This module authorizes the form it actually
  # passes instead. Documented divergence, not an accidental widening.
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
        # aws:SourceAccount only. An ArnLike on
        # "arn:<partition>:ecs:<region>:<account>:*" was tried and removed: it
        # matches every ECS resource ARN in the account, so it excluded nothing
        # while reading like a control. ECS does not expose the task-definition
        # ARN as aws:SourceArn at AssumeRole time, so there is no narrower value
        # to pin; the cross-account confused-deputy case is what SourceAccount
        # closes, and that is stated rather than overclaimed.
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
        Resource = "arn:${local.partition}:ec2:${local.region}:${local.account_id}:volume/*"
      },
      {
        Sid      = "CreateTaggedSnapshot"
        Effect   = "Allow"
        Action   = "ec2:CreateSnapshot"
        Resource = "arn:${local.partition}:ec2:${local.region}::snapshot/*"
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
        Resource = "arn:${local.partition}:ec2:${local.region}::snapshot/*"
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
        Resource = "arn:${local.partition}:ec2:${local.region}::snapshot/*"
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
        # aws:SourceAccount only. An ArnLike on
        # "arn:<partition>:ecs:<region>:<account>:*" was tried and removed: it
        # matches every ECS resource ARN in the account, so it excluded nothing
        # while reading like a control. ECS does not expose the task-definition
        # ARN as aws:SourceArn at AssumeRole time, so there is no narrower value
        # to pin; the cross-account confused-deputy case is what SourceAccount
        # closes, and that is stated rather than overclaimed.
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
        # Without this any EventBridge rule in the account could assume this role
        # and use its ecs:RunTask + iam:PassRole grants to launch the scanner
        # task. The rule does not reference the role, so there is no cycle.
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
        # aws:SourceAccount, matching the other three roles. An ArnLike on
        # aws:SourceArn is included here because a Lambda function ARN pattern is
        # meaningfully narrow, unlike the ECS one that was tried on the task and
        # execution roles and removed for matching every ARN in the account.
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
        # The function refuses to start a second orchestrator while one is
        # already running. Without this the ListTasks call is denied on every
        # invocation, the bare except swallows it, and the guard never fires.
        Sid       = "InitialScanCheckForRunningScan"
        Effect    = "Allow"
        Action    = "ecs:ListTasks"
        Resource  = "*"
        Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
      },
    ])
  })
}
