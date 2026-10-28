# NOTE: `terraform test` on this file needs Terraform >= 1.7 (mock_provider),
# stricter than the module's own required_version. Plan/apply is unaffected.

# The expected documents below are transcribed from the console's CloudFormation
# access stack (StreamScannerSpokeRole). A change there is a change here.

mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::444455556666:role/StreamScannerSpokeRole" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "444455556666" }
  }
  # The rest serve the runs of ../volume-scanner, the hub this role trusts.
  mock_data "aws_region" {
    defaults = { region = "eu-west-1" }
  }
  mock_data "aws_ecs_clusters" {
    defaults = { cluster_arns = [] }
  }
  mock_data "aws_vpc_endpoint_service" {
    defaults = {
      service_name       = "com.amazonaws.eu-west-1.resolved"
      availability_zones = ["eu-west-1a"]
    }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-west-1a"] }
  }
}

mock_provider "streamsec" {
  mock_data "streamsec_aws_scanner_hub_access" {
    defaults = {
      hub_cloud_account_id       = "111122223333"
      role_name                  = "StreamScannerSpokeRole"
      external_id                = "EXTID123"
      trusted_role_name_patterns = ["streamsec-scanner-*", "*streamsec-ebs-scanner-tf-*"]
    }
  }
  mock_data "streamsec_host" {
    defaults = { url = "https://acme.streamsec.io" }
  }
  mock_data "streamsec_aws_account" {
    defaults = {
      id                         = "stream-hub-1"
      cloud_account_id           = "111122223333"
      streamsec_collection_token = "collection-token"
    }
  }
}

mock_provider "archive" {}

variables {
  hub_account_id = "stream-hub-1"
}

run "role_has_the_exact_name_the_hub_assumes" {
  command = plan

  assert {
    condition     = aws_iam_role.this.name == "StreamScannerSpokeRole"
    error_message = "The role must be named exactly StreamScannerSpokeRole: the hub's AssumeSpokeAccessRoles grant names it."
  }

  # Unset is the provider's "/" default.
  assert {
    condition     = aws_iam_role.this.path == null || aws_iam_role.this.path == "/"
    error_message = "The hub builds arn:<p>:iam::<spoke>:role/StreamScannerSpokeRole, so the role must have no path."
  }

  assert {
    condition     = aws_iam_role.this.max_session_duration == 3600
    error_message = "MaxSessionDuration must be 3600, as in the CloudFormation access stack."
  }

  assert {
    condition     = data.streamsec_aws_scanner_hub_access.this.hub_account_id == "stream-hub-1"
    error_message = "The hub's access parameters must be read for hub_account_id."
  }
}

run "trust_admits_only_the_hubs_scanner" {
  command = plan

  assert {
    condition = jsonencode(jsondecode(aws_iam_role.this.assume_role_policy)) == jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect    = "Allow"
          Principal = { AWS = "arn:aws:iam::111122223333:root" }
          Action    = "sts:AssumeRole"
          Condition = {
            StringEquals = { "sts:ExternalId" = "EXTID123" }
            StringLike = {
              "aws:PrincipalArn" = [
                "arn:aws:iam::111122223333:role/streamsec-scanner-*",
                "arn:aws:iam::111122223333:role/*streamsec-ebs-scanner-tf-*",
              ]
            }
          }
        },
      ]
    })
    error_message = "The trust must be the hub account's root, the hub's external id, and one aws:PrincipalArn per trusted role name pattern."
  }
}

# The hub role names the trust must admit, taken from the volume-scanner module
# itself, with and without a resource_prefix.
run "terraform_hub_role_name" {
  command = plan

  module {
    source = "../volume-scanner"
  }

  variables {
    customer_id = "customer-abc"
  }
}

run "prefixed_terraform_hub_role_name" {
  command = plan

  module {
    source = "../volume-scanner"
  }

  variables {
    customer_id     = "customer-abc"
    resource_prefix = "acme-prd"
  }
}

# The rendered patterns, read as IAM StringLike globs, admit the real hub role
# names: both of the volume-scanner module's and the console stack's
# streamsec-scanner-<region> (a literal: the CloudFormation template is not
# reachable from here). And not just any role in the hub account.
run "trust_admits_the_real_hub_role_names" {
  command = plan

  assert {
    condition = alltrue([
      for name in [
        run.terraform_hub_role_name.task_role_name,
        run.prefixed_terraform_hub_role_name.task_role_name,
        "streamsec-scanner-eu-west-1",
        ] : anytrue([
          for arn in jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringLike["aws:PrincipalArn"] :
          length(regexall(
            "^${replace(replace(replace(trimprefix(arn, "arn:aws:iam::111122223333:role/"), ".", "\\."), "*", ".*"), "?", ".")}$",
            name,
          )) > 0
      ])
    ])
    error_message = "Every real hub scanner role name must match one of the trust's aws:PrincipalArn patterns."
  }

  assert {
    condition = !anytrue([
      for arn in jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringLike["aws:PrincipalArn"] :
      length(regexall(
        "^${replace(replace(replace(trimprefix(arn, "arn:aws:iam::111122223333:role/"), ".", "\\."), "*", ".*"), "?", ".")}$",
        "OrganizationAccountAccessRole",
      )) > 0
    ])
    error_message = "The trust must not admit an unrelated role of the hub account."
  }

  # So the names above are the module's real ones, not an empty or unprefixed stand-in.
  assert {
    condition = alltrue([
      endswith(run.terraform_hub_role_name.task_role_name, "-eu-west-1-task-role"),
      startswith(run.prefixed_terraform_hub_role_name.task_role_name, "acme-prd-"),
    ])
    error_message = "The hub role names read from ../volume-scanner must be its regional task role names."
  }
}

# One ARN per pattern, in order, whatever the API returns: nothing is hardcoded.
run "trust_has_one_principal_arn_per_pattern" {
  command = plan

  override_data {
    target = data.streamsec_aws_scanner_hub_access.this
    values = {
      hub_cloud_account_id       = "999988887777"
      role_name                  = "StreamScannerSpokeRole"
      external_id                = "OTHERID9"
      trusted_role_name_patterns = ["a-*", "*b-*", "c"]
    }
  }

  assert {
    condition = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringLike["aws:PrincipalArn"] == [
      "arn:aws:iam::999988887777:role/a-*",
      "arn:aws:iam::999988887777:role/*b-*",
      "arn:aws:iam::999988887777:role/c",
    ]
    error_message = "aws:PrincipalArn must hold exactly one hub role ARN per trusted_role_name_patterns entry."
  }

  assert {
    condition = alltrue([
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Principal.AWS == "arn:aws:iam::999988887777:root",
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringEquals["sts:ExternalId"] == "OTHERID9",
    ])
    error_message = "The hub account and external id must come from the data source."
  }
}

run "policy_mirrors_the_cloudformation_access_stack" {
  command = plan

  assert {
    condition     = aws_iam_role_policy.this.name == "StreamScannerAccess"
    error_message = "The inline policy must be named StreamScannerAccess, as in the CloudFormation access stack."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.this.policy).Version == "2012-10-17"
    error_message = "The policy must use version 2012-10-17."
  }

  assert {
    condition = [for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s.Sid] == [
      "Discover",
      "CreateSnapshotOnVolume",
      "CreateTaggedSnapshot",
      "TagSnapshotsAtCreate",
      "ReadAndDeleteOwnSnapshots",
      "DecryptEncryptedVolumes",
      "WorkloadDiscoveryList",
      "WorkloadDiscoveryGet",
      "WorkloadImageAuth",
      "WorkloadImagePull",
    ]
    error_message = "The policy must hold the CloudFormation access stack's statements, no more, no fewer, in its order."
  }

  assert {
    condition = jsonencode([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if s.Sid == "Discover"][0]) == jsonencode({
      Sid      = "Discover"
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances", "ec2:DescribeVolumes", "ec2:DescribeSnapshots"]
      Resource = "*"
    })
    error_message = "Discover differs from the CloudFormation access stack."
  }

  assert {
    condition = jsonencode([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if s.Sid == "CreateSnapshotOnVolume"][0]) == jsonencode({
      Sid      = "CreateSnapshotOnVolume"
      Effect   = "Allow"
      Action   = "ec2:CreateSnapshot"
      Resource = "arn:aws:ec2:*:*:volume/*"
    })
    error_message = "CreateSnapshotOnVolume differs from the CloudFormation access stack."
  }

  assert {
    condition = jsonencode([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if s.Sid == "CreateTaggedSnapshot"][0]) == jsonencode({
      Sid       = "CreateTaggedSnapshot"
      Effect    = "Allow"
      Action    = "ec2:CreateSnapshot"
      Resource  = "arn:aws:ec2:*:*:snapshot/*"
      Condition = { StringEquals = { "aws:RequestTag/Purpose" = "ebs-package-collector" } }
    })
    error_message = "CreateTaggedSnapshot differs from the CloudFormation access stack."
  }

  assert {
    condition = jsonencode([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if s.Sid == "TagSnapshotsAtCreate"][0]) == jsonencode({
      Sid       = "TagSnapshotsAtCreate"
      Effect    = "Allow"
      Action    = ["ec2:CreateTags"]
      Resource  = "arn:aws:ec2:*:*:snapshot/*"
      Condition = { StringEquals = { "ec2:CreateAction" = "CreateSnapshot" } }
    })
    error_message = "TagSnapshotsAtCreate differs from the CloudFormation access stack."
  }

  assert {
    condition = jsonencode([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if s.Sid == "ReadAndDeleteOwnSnapshots"][0]) == jsonencode({
      Sid       = "ReadAndDeleteOwnSnapshots"
      Effect    = "Allow"
      Action    = ["ec2:DeleteSnapshot", "ebs:ListSnapshotBlocks", "ebs:GetSnapshotBlock"]
      Resource  = "arn:aws:ec2:*:*:snapshot/*"
      Condition = { StringEquals = { "aws:ResourceTag/Purpose" = "ebs-package-collector" } }
    })
    error_message = "ReadAndDeleteOwnSnapshots differs from the CloudFormation access stack."
  }

  assert {
    condition = jsonencode([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if s.Sid == "DecryptEncryptedVolumes"][0]) == jsonencode({
      Sid       = "DecryptEncryptedVolumes"
      Effect    = "Allow"
      Action    = ["kms:Decrypt", "kms:DescribeKey"]
      Resource  = "*"
      Condition = { StringLike = { "kms:ViaService" = "ec2.*.amazonaws.com" } }
    })
    error_message = "DecryptEncryptedVolumes differs from the CloudFormation access stack."
  }

  assert {
    condition = jsonencode([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if s.Sid == "WorkloadDiscoveryList"][0]) == jsonencode({
      Sid      = "WorkloadDiscoveryList"
      Effect   = "Allow"
      Action   = ["lambda:ListFunctions", "ecs:ListClusters", "ecs:ListTasks", "ecs:DescribeTasks", "ecs:DescribeTaskDefinition"]
      Resource = "*"
    })
    error_message = "WorkloadDiscoveryList differs from the CloudFormation access stack."
  }

  assert {
    condition = jsonencode([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if s.Sid == "WorkloadDiscoveryGet"][0]) == jsonencode({
      Sid      = "WorkloadDiscoveryGet"
      Effect   = "Allow"
      Action   = ["lambda:GetFunction", "lambda:GetLayerVersion"]
      Resource = ["arn:aws:lambda:*:*:function:*", "arn:aws:lambda:*:*:layer:*:*"]
    })
    error_message = "WorkloadDiscoveryGet differs from the CloudFormation access stack."
  }

  assert {
    condition = jsonencode([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if s.Sid == "WorkloadImageAuth"][0]) == jsonencode({
      Sid      = "WorkloadImageAuth"
      Effect   = "Allow"
      Action   = ["ecr:GetAuthorizationToken"]
      Resource = "*"
    })
    error_message = "WorkloadImageAuth differs from the CloudFormation access stack."
  }

  assert {
    condition = jsonencode([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s if s.Sid == "WorkloadImagePull"][0]) == jsonencode({
      Sid      = "WorkloadImagePull"
      Effect   = "Allow"
      Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
      Resource = "arn:aws:ecr:*:*:repository/*"
    })
    error_message = "WorkloadImagePull differs from the CloudFormation access stack."
  }
}

run "policy_is_attached_to_the_spoke_role" {
  command = apply

  assert {
    condition     = aws_iam_role_policy.this.role == aws_iam_role.this.id
    error_message = "The access policy must be attached to StreamScannerSpokeRole."
  }
}

# The one place the CloudFormation template is not partition-aware: its KMS
# ViaService suffix. aws-cn service endpoints end .amazonaws.com.cn.
run "every_arn_follows_the_partition" {
  command = plan

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws-cn" }
  }

  assert {
    condition = alltrue([
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Principal.AWS == "arn:aws-cn:iam::111122223333:root",
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringLike["aws:PrincipalArn"] == [
        "arn:aws-cn:iam::111122223333:role/streamsec-scanner-*",
        "arn:aws-cn:iam::111122223333:role/*streamsec-ebs-scanner-tf-*",
      ],
    ])
    error_message = "The trust's principal and principal ARNs must use the aws-cn partition."
  }

  assert {
    condition = alltrue([
      for arn in flatten([for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s.Resource]) :
      arn == "*" || startswith(arn, "arn:aws-cn:")
    ])
    error_message = "Every policy resource ARN must use the aws-cn partition."
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.this.policy).Statement : s.Condition.StringLike["kms:ViaService"] if s.Sid == "DecryptEncryptedVolumes"
    ] == ["ec2.*.amazonaws.com.cn"]
    error_message = "In aws-cn kms:ViaService must end .amazonaws.com.cn."
  }
}

run "access_is_acknowledged_for_this_account" {
  command = apply

  variables {
    hub_account_id = "  stream-hub-1\n"
  }

  assert {
    condition     = streamsec_aws_scanner_access_ack.this.hub_account_id == "stream-hub-1"
    error_message = "The acknowledgement must name the hub's Stream id, trimmed."
  }

  assert {
    condition     = streamsec_aws_scanner_access_ack.this.spoke_cloud_account_id == "444455556666"
    error_message = "The acknowledgement must name this account's 12-digit id."
  }
}

run "tags_identify_the_role" {
  command = plan

  variables {
    tags = { team = "security" }
  }

  assert {
    condition     = aws_iam_role.this.tags == tomap({ "streamsec:component" = "scanner-access", team = "security" })
    error_message = "The role must carry the streamsec:component tag and the supplied tags."
  }
}

# If Stream ever names the role differently, the hub assumes a role this module
# did not create: fail rather than create one nobody uses.
run "a_role_name_other_than_the_hubs_grant_is_refused" {
  command = plan

  override_data {
    target = data.streamsec_aws_scanner_hub_access.this
    values = {
      hub_cloud_account_id       = "111122223333"
      role_name                  = "SomeOtherRole"
      external_id                = "EXTID123"
      trusted_role_name_patterns = ["streamsec-scanner-*"]
    }
  }

  expect_failures = [aws_iam_role.this]
}

run "no_trusted_patterns_is_refused" {
  command = plan

  override_data {
    target = data.streamsec_aws_scanner_hub_access.this
    values = {
      hub_cloud_account_id       = "111122223333"
      role_name                  = "StreamScannerSpokeRole"
      external_id                = "EXTID123"
      trusted_role_name_patterns = []
    }
  }

  expect_failures = [aws_iam_role.this]
}

run "blank_hub_account_id_is_rejected" {
  command = plan

  variables {
    hub_account_id = "  "
  }

  expect_failures = [var.hub_account_id]
}
