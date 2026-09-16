# NOTE: `terraform test` on this file needs Terraform >= 1.7 (mock_provider),
# stricter than the module's own required_version. Plan/apply is unaffected.

mock_provider "aws" {
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111111111111:cluster/mock-scanner" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111111111111:task-definition/streamsec-ebs-scanner-tf:1" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/mock-scanner-role" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  # No CloudFormation-deployed scanner in the region unless a run overrides this.
  mock_data "aws_ecs_clusters" {
    defaults = { cluster_arns = [] }
  }
  mock_data "aws_vpc_endpoint_service" {
    defaults = {
      service_name       = "com.amazonaws.us-east-1.resolved"
      availability_zones = ["us-east-1a", "us-east-1b"]
    }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b"] }
  }
}

mock_provider "streamsec" {
  mock_data "streamsec_host" {
    defaults = { url = "https://acme.streamsec.io" }
  }
  mock_data "streamsec_aws_account" {
    defaults = {
      cloud_account_id           = "111111111111"
      streamsec_collection_token = "collection-token"
    }
  }
}

mock_provider "archive" {}

variables {
  customer_id = "customer-abc"
}

run "container_environment_matches_the_cloudformation_defaults" {
  command = apply

  assert {
    condition = alltrue([
      for pair in ["COLLECTOR_SCAN_LANGUAGE_PACKAGES=true",
        "COLLECTOR_SCAN_DATABASES=false",
        "COLLECTOR_SCAN_AI_WORKLOADS=false",
        "COLLECTOR_SCAN_SECRETS=false",
        "COLLECTOR_WORKLOAD_KINDS=lambda,ecs",
        "COLLECTOR_ROLE=orchestrator",
        "COLLECTOR_SHARD_SIZE=100",
      "COLLECTOR_MAX_CONCURRENT_SHARDS=10"] :
      contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], pair)
    ])
    error_message = "Default container environment does not match the CloudFormation defaults."
  }

  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], "COLLECTOR_TENANT_NAME=acme")
    error_message = "COLLECTOR_TENANT_NAME must come from the first label of the host URL."
  }

  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], "COLLECTOR_STREAM_SCAN_URL=https://acme.streamsec.io/openapi/vulnerabilities/stream_scan/raw")
    error_message = "COLLECTOR_STREAM_SCAN_URL must be the host plus /stream_scan/raw."
  }

  assert {
    condition = alltrue([
      for pair in ["COLLECTOR_CUSTOMER_ID=customer-abc", "COLLECTOR_STREAM_SCAN_WORKSPACE=customer-abc"] :
      contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], pair)
    ])
    error_message = "Customer id and scan workspace must both carry customer_id."
  }

  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], "COLLECTOR_ECS_TASK_DEF_ARN=arn:aws:ecs:us-east-1:111111111111:task-definition/streamsec-ebs-scanner-tf")
    error_message = "COLLECTOR_ECS_TASK_DEF_ARN must be the revision-less family ARN."
  }

  # The three values the orchestrator launches children WITH; nothing else asserts
  # them, so a mis-wired one fails fan-out at runtime with the suite green.
  assert {
    condition = alltrue([
      for pair in [
        "COLLECTOR_ECS_CLUSTER_ARN=${aws_ecs_cluster.this.arn}",
        "COLLECTOR_ECS_SUBNET_IDS=${join(",", aws_subnet.private[*].id)}",
        "COLLECTOR_ECS_SECURITY_GROUP_ID=${aws_security_group.this.id}",
      ] :
      contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], pair)
    ])
    error_message = "Fan-out env (cluster ARN, subnet ids, security group) must point at this module's resources."
  }
}

# The container used to receive var.workload_kinds verbatim while IAM used the
# trimmed list, so "lambda, ecs" sent " ecs" to the scanner, matching no kind.
run "workload_kinds_reach_the_container_normalized" {
  command = apply

  variables {
    workload_kinds = "ecs, lambda"
  }

  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], "COLLECTOR_WORKLOAD_KINDS=ecs,lambda")
    error_message = "COLLECTOR_WORKLOAD_KINDS must be the trimmed, normalized list."
  }
}

run "feature_toggles_reach_the_container" {
  command = apply

  variables {
    scan_secrets           = true
    scan_ai_workloads      = true
    scan_databases         = true
    scan_language_packages = false
    workload_kinds         = ""
    shard_size             = 250
    max_concurrent_shards  = 25
  }

  assert {
    condition = alltrue([
      for pair in ["COLLECTOR_SCAN_SECRETS=true",
        "COLLECTOR_SCAN_AI_WORKLOADS=true",
        "COLLECTOR_SCAN_DATABASES=true",
        "COLLECTOR_SCAN_LANGUAGE_PACKAGES=false",
        "COLLECTOR_WORKLOAD_KINDS=",
        "COLLECTOR_SHARD_SIZE=250",
      "COLLECTOR_MAX_CONCURRENT_SHARDS=25"] :
      contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], pair)
    ])
    error_message = "Scanner toggles and scaling knobs must reach the container environment."
  }
}

run "task_sizing_matches_the_cloudformation_template" {
  command = plan

  assert {
    condition     = aws_ecs_task_definition.this.cpu == "4096" && aws_ecs_task_definition.this.memory == "16384"
    error_message = "Default task sizing must stay 4096 CPU / 16384 memory."
  }

  assert {
    condition     = aws_ecs_task_definition.this.ephemeral_storage[0].size_in_gib == 50
    error_message = "Ephemeral storage must default to 50 GiB."
  }

  assert {
    condition     = aws_ecs_task_definition.this.family == "streamsec-ebs-scanner-tf"
    error_message = "Task family must stay streamsec-ebs-scanner-tf, distinct from the CloudFormation family."
  }
}

run "schedule_uses_cron_not_rate" {
  command = plan

  assert {
    condition     = aws_cloudwatch_event_rule.daily.schedule_expression == "cron(0 3 * * ? *)"
    error_message = "The schedule must be a cron expression, not rate(...)."
  }
}

run "initial_scan_can_be_disabled" {
  command = plan

  variables {
    trigger_initial_scan = false
  }

  assert {
    condition = alltrue([
      length(aws_lambda_function.initial_scan) == 0,
      length(aws_lambda_invocation.initial_scan) == 0,
      length(aws_iam_role.initial_scan) == 0,
    ])
    error_message = "trigger_initial_scan = false must drop the Lambda, invocation and role."
  }
}

run "initial_scan_is_created_by_default" {
  command = plan

  assert {
    condition = alltrue([
      length(aws_lambda_function.initial_scan) == 1,
      length(aws_lambda_invocation.initial_scan) == 1,
      length(aws_iam_role.initial_scan) == 1,
    ])
    error_message = "By default the initial-scan Lambda, invocation and role must exist."
  }
}

# command = apply, not plan: random_string is unmocked, so the secret name is
# unknown at plan and both assertions below come out indeterminate — skipped
# rather than passed.
run "resource_prefix_is_applied" {
  command = apply

  variables {
    resource_prefix = "acme"
  }

  assert {
    condition     = aws_ecs_cluster.this.name == "acme-streamsec-ebs-scanner-tf-us-east-1"
    error_message = "Resource names must carry resource_prefix and the region."
  }

  # name_prefix is the configured argument, so it is known here; .name is
  # provider-generated and under mock_provider is a random token, so nothing
  # about it can be asserted in this suite.
  assert {
    condition     = aws_secretsmanager_secret.collection_token.name_prefix == "acme-streamsec-scanner-collection-token-us-east-1-"
    error_message = "The secret prefix must carry resource_prefix and the region."
  }
}

run "refuses_to_deploy_alongside_the_cloudformation_scanner" {
  command = plan

  override_data {
    target = data.aws_ecs_clusters.existing
    values = {
      cluster_arns = ["arn:aws:ecs:us-east-1:111111111111:cluster/streamsec-ebs-scanner-us-east-1"]
    }
  }

  # All three, not just the cluster: the VPC (and the NAT downstream of it) costs
  # money, an identically named cluster is silently adopted, and the secret holds
  # the collection token. The VPC needs its own guard — it does not depend on the
  # cluster. IAM roles and log groups may still be created, but are inert.
  expect_failures = [
    aws_ecs_cluster.this,
    aws_vpc.this,
    aws_secretsmanager_secret.collection_token,
  ]
}

run "coexistence_can_be_opted_into" {
  command = plan

  variables {
    allow_cloudformation_coexistence = true
  }

  override_data {
    target = data.aws_ecs_clusters.existing
    values = {
      cluster_arns = ["arn:aws:ecs:us-east-1:111111111111:cluster/streamsec-ebs-scanner-us-east-1"]
    }
  }

  assert {
    condition     = aws_ecs_cluster.this.name == "streamsec-ebs-scanner-tf-us-east-1"
    error_message = "allow_cloudformation_coexistence must permit the deploy, keeping our own cluster name."
  }
}

# The module's own cluster must never be mistaken for the CloudFormation one, or
# every re-apply would trip the guard.
# already_installed: BOTH clusters present. This is the whole "a CloudFormation
# scanner appearing later must not lock a healthy Terraform deployment out of its
# own applies" argument, and no fixture supplied both until now.
run "an_existing_deployment_is_not_locked_out_by_a_later_cfn_stack" {
  command = plan

  override_data {
    target = data.aws_ecs_clusters.existing
    values = {
      cluster_arns = [
        "arn:aws:ecs:us-east-1:111111111111:cluster/streamsec-ebs-scanner-us-east-1",
        "arn:aws:ecs:us-east-1:111111111111:cluster/streamsec-ebs-scanner-tf-us-east-1",
      ]
    }
  }

  assert {
    condition     = aws_ecs_cluster.this.name == "streamsec-ebs-scanner-tf-us-east-1"
    error_message = "With this module's own cluster already present the plan must succeed, even alongside a CloudFormation scanner."
  }
}

# The duplicate-Terraform-scanner branch: a second -tf cluster under a different
# resource_prefix. This is also the ONLY branch that emits the resource_prefix
# rename hint, so that advice was untested.
run "a_second_terraform_scanner_trips_the_guard" {
  command = plan

  override_data {
    target = data.aws_ecs_clusters.existing
    values = {
      cluster_arns = ["arn:aws:ecs:us-east-1:111111111111:cluster/other-streamsec-ebs-scanner-tf-us-east-1"]
    }
  }

  # All three gated resources, as the CloudFormation-coexistence run asserts:
  # the VPC and secret carry the guard independently of the cluster.
  expect_failures = [
    aws_ecs_cluster.this,
    aws_vpc.this,
    aws_secretsmanager_secret.collection_token,
  ]
}

run "our_own_cluster_does_not_trip_the_guard" {
  command = plan

  override_data {
    target = data.aws_ecs_clusters.existing
    values = {
      cluster_arns = ["arn:aws:ecs:us-east-1:111111111111:cluster/streamsec-ebs-scanner-tf-us-east-1"]
    }
  }

  assert {
    condition     = aws_ecs_cluster.this.name == "streamsec-ebs-scanner-tf-us-east-1"
    error_message = "Our own -tf cluster must not trip the CloudFormation presence check."
  }
}

run "names_cannot_collide_with_the_cloudformation_stack" {
  command = plan

  assert {
    condition = alltrue([
      aws_ecs_cluster.this.name != "streamsec-ebs-scanner-us-east-1",
      aws_ecs_task_definition.this.family != "streamsec-ebs-scanner",
      aws_cloudwatch_log_group.this.name != "/ecs/streamsec-ebs-scanner-us-east-1",
    ])
    error_message = "Cluster, task family and log group must differ from the CloudFormation names."
  }
}

# Regression: a region with no ECS clusters returns null, not [], and iterating
# it aborts the plan. The mock default of [] hides this, so pin it explicitly.
run "region_with_no_ecs_clusters_still_plans" {
  command = plan

  override_data {
    target = data.aws_ecs_clusters.existing
    values = {
      cluster_arns = null
    }
  }

  assert {
    condition     = aws_ecs_cluster.this.name == "streamsec-ebs-scanner-tf-us-east-1"
    error_message = "A region with null cluster_arns must still plan."
  }
}

run "customer_id_is_required" {
  command = plan

  variables {
    customer_id = null
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "collection_token_is_injected_from_secrets_manager" {
  command = apply

  assert {
    condition = length([
      for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment :
      e if e.name == "COLLECTOR_STREAM_SCAN_TOKEN"
    ]) == 0
    error_message = "The collection token must never be a plaintext environment variable."
  }

  assert {
    condition = length([
      for s in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets :
      s if s.name == "COLLECTOR_STREAM_SCAN_TOKEN" && s.valueFrom == aws_secretsmanager_secret.collection_token.arn
    ]) == 1
    error_message = "The collection token must come from the secrets block, sourced from this module's secret."
  }

  assert {
    condition = contains(
      jsondecode(aws_iam_role_policy.execution_secrets.policy).Statement[0].Action,
      "secretsmanager:GetSecretValue"
    )
    error_message = "The execution role must hold secretsmanager:GetSecretValue."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.execution_secrets.policy).Statement[0].Resource == aws_secretsmanager_secret.collection_token.arn
    error_message = "GetSecretValue must be scoped to this module's own secret ARN."
  }
}

run "workload_iam_is_dropped_when_workload_scanning_is_off" {
  command = plan

  variables {
    workload_kinds = ""
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement :
      s if startswith(s.Sid, "Workload")
    ]) == 0
    error_message = "Empty workload_kinds must attach no Workload* statements."
  }
}

run "workload_iam_is_present_by_default" {
  command = plan

  assert {
    condition = alltrue([
      for sid in ["WorkloadLambdaList", "WorkloadLambdaGet", "WorkloadEcsDiscovery", "WorkloadImageAuth", "WorkloadImagePull"] :
      contains([for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Sid], sid)
    ])
    error_message = "Default workload_kinds must grant every Workload* statement."
  }
}

run "workload_iam_is_scoped_to_lambda_only" {
  command = plan

  variables {
    workload_kinds = "lambda"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement :
      s if startswith(s.Sid, "WorkloadEcs")
    ]) == 0
    error_message = "workload_kinds = lambda must grant no WorkloadEcs statements."
  }

  assert {
    condition = alltrue([
      for sid in ["WorkloadLambdaList", "WorkloadLambdaGet", "WorkloadImageAuth", "WorkloadImagePull"] :
      contains([for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Sid], sid)
    ])
    error_message = "workload_kinds = lambda must keep the Lambda and ECR statements."
  }
}

run "workload_iam_is_scoped_to_ecs_only" {
  command = plan

  variables {
    workload_kinds = "ecs"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement :
      s if startswith(s.Sid, "WorkloadLambda")
    ]) == 0
    error_message = "workload_kinds = ecs must grant no WorkloadLambda statements."
  }

  assert {
    condition = alltrue([
      for sid in ["WorkloadEcsDiscovery", "WorkloadImageAuth", "WorkloadImagePull"] :
      contains([for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Sid], sid)
    ])
    error_message = "workload_kinds = ecs must keep the ECS and ECR statements."
  }
}

run "run_task_is_scoped_to_the_scanner_cluster" {
  command = apply

  # flatten([s.Action]) normalises the string and list forms of Action; a filter
  # matching nothing yields alltrue([]) == true. flatten() around the OUTER list
  # matters too, or length() counts the three per-policy lists and always gets 3.
  assert {
    condition = length(flatten([
      for policy in [
        aws_iam_role_policy.orchestrator.policy,
        aws_iam_role_policy.events.policy,
        aws_iam_role_policy.initial_scan[0].policy,
        ] : [
        for s in jsondecode(policy).Statement :
        s if contains(flatten([s.Action]), "ecs:RunTask")
      ]
    ])) == 3
    error_message = "Expected one ecs:RunTask statement in each of the three launcher policies."
  }

  assert {
    condition = alltrue(flatten([
      for policy in [
        aws_iam_role_policy.orchestrator.policy,
        aws_iam_role_policy.events.policy,
        aws_iam_role_policy.initial_scan[0].policy,
        ] : [
        for s in jsondecode(policy).Statement :
        try(s.Condition.ArnEquals["ecs:cluster"], null) == aws_ecs_cluster.this.arn
        if contains(flatten([s.Action]), "ecs:RunTask")
      ]
    ]))
    error_message = "Every ecs:RunTask grant must be conditioned on the scanner's own cluster."
  }
}

# The duplicate-scan guard in initial_scan.py calls ecs:ListTasks; the grant once
# landed on the EventBridge role instead and the guard stayed dead.
run "initial_scan_role_can_check_for_a_running_scan" {
  command = apply

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.initial_scan[0].policy).Statement :
      s if contains(flatten([s.Action]), "ecs:ListTasks")
    ]) == 1
    error_message = "The initial-scan role must hold ecs:ListTasks for the duplicate-scan guard."
  }

  # Asserted per ROLE, not per policy: aws_iam_role_policy.task sits on the same
  # role and grants ListTasks account-wide, so a per-policy filter misses it.
  assert {
    condition = length([
      for s in concat(
        jsondecode(aws_iam_role_policy.events.policy).Statement,
      ) : s if contains(flatten([s.Action]), "ecs:ListTasks")
    ]) == 0
    error_message = "The EventBridge role must not hold ecs:ListTasks."
  }

  # The scanner task role DOES hold account-wide ecs:ListTasks for workload
  # discovery, so it is asserted as expected rather than absent.
  assert {
    condition = length([
      for s in concat(
        jsondecode(aws_iam_role_policy.task.policy).Statement,
        jsondecode(aws_iam_role_policy.orchestrator.policy).Statement,
      ) : s if contains(flatten([s.Action]), "ecs:ListTasks")
    ]) == 1
    error_message = "The task role must hold exactly one account-wide ecs:ListTasks."
  }
}

# Covers kms_endpoint_suffix only. vpc_endpoint_service_prefix is NOT exercised
# here — the endpoint services are mocked, so the aws-cn prefix stays untested.
run "kms_via_service_is_partition_correct_in_china" {
  command = plan

  # public.ecr.aws is unreachable from aws-cn, so a China deployment must supply
  # a mirrored image; the default would trip the precondition below.
  variables {
    scanner_image = "111122223333.dkr.ecr.cn-north-1.amazonaws.com.cn/stream/volume-scanner:latest"
  }

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws-cn" }
  }

  override_data {
    target = data.aws_region.current
    values = { region = "cn-north-1" }
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement :
      try(s.Condition.StringEquals["kms:ViaService"], []) if s.Sid == "ReadEncryptedVolumes"
    ][0] == ["ec2.cn-north-1.amazonaws.com.cn"]
    error_message = "In aws-cn kms:ViaService must use the .amazonaws.com.cn suffix."
  }
}

# The only run asserting s.Resource on the RunTask grants: the run above checks
# the count and the ecs:cluster condition, so a swapped or widened ARN passes it.
run "run_task_resources_keep_their_deliberate_split" {
  command = apply

  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.orchestrator.policy).Statement :
      flatten([s.Resource]) if try(s.Sid, "") == "RunScannerTask"
      ])) == toset([
      local.task_definition_family_arn,
      "${local.task_definition_family_arn}:*",
    ])
    error_message = "The orchestrator's RunTask grant must stay on the family ARN and family ARN:*."
  }

  assert {
    condition = length(flatten([
      for policy in [
        aws_iam_role_policy.events.policy,
        aws_iam_role_policy.initial_scan[0].policy,
        ] : [
        for s in jsondecode(policy).Statement : s if try(s.Sid, "") == "RunScannerTask"
      ]
    ])) == 2
    error_message = "A RunScannerTask statement went missing from events or initial_scan."
  }

  assert {
    condition = alltrue([
      for policy in [
        aws_iam_role_policy.events.policy,
        aws_iam_role_policy.initial_scan[0].policy,
        ] : alltrue([
          for s in jsondecode(policy).Statement :
          flatten([s.Resource]) == [aws_ecs_task_definition.this.arn]
          if try(s.Sid, "") == "RunScannerTask"
      ])
    ])
    error_message = "EventBridge and initial-scan RunTask grants must stay pinned to the revision ARN."
  }
}

run "kms_grant_matches_the_cloudformation_template_exactly" {
  command = plan

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement :
      s if s.Sid == "ReadEncryptedVolumes"
    ][0].Condition.StringEquals["kms:ViaService"] == ["ec2.us-east-1.amazonaws.com"]
    error_message = "kms:ViaService must be exactly ec2.<region>."
  }

  assert {
    condition = toset([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement :
      s if s.Sid == "ReadEncryptedVolumes"
    ][0].Action) == toset(["kms:Decrypt", "kms:DescribeKey"])
    error_message = "The KMS grant must be exactly kms:Decrypt + kms:DescribeKey."
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement :
      s if s.Sid == "GrantEC2SnapshotAccessToKeys"
    ]) == 0
    error_message = "kms:CreateGrant must never be granted."
  }
}

# The default image is unreachable from aws-cn, so it should fail at plan with
# the reason rather than at task start with an opaque CannotPullContainerError.
run "china_partition_rejects_the_public_ecr_default_image" {
  command = plan

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws-cn" }
  }

  override_data {
    target = data.aws_region.current
    values = { region = "cn-north-1" }
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "whitespace_only_workload_kinds_is_rejected" {
  command = plan

  variables {
    workload_kinds = "  "
  }

  expect_failures = [var.workload_kinds]
}

run "secret_name_is_generated_not_fixed" {
  command = apply

  # A fixed name is the bug: identical on both sides of a create_before_destroy
  # replacement, so the new secret fails with ResourceExistsException. The
  # module must hand the provider a prefix and let it generate the rest.
  # Reproduced and fixed against real Secrets Manager on 2026-09-16.
  assert {
    condition     = aws_secretsmanager_secret.collection_token.name_prefix == "streamsec-scanner-collection-token-us-east-1-"
    error_message = "The secret must be created with name_prefix, not a fixed name."
  }

  # Trailing hyphen keeps the generated suffix cleanly separated from the prefix.
  assert {
    condition     = endswith(aws_secretsmanager_secret.collection_token.name_prefix, "-")
    error_message = "The secret prefix must end in a hyphen."
  }
}

# No other run asserts the snapshot statements; every one filters on Workload*
# or the KMS Sids.
run "snapshot_grants_keep_their_scoping_conditions" {
  command = plan

  assert {
    condition = try([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement :
      s if s.Sid == "ReadAndDeleteOwnSnapshots"
    ][0].Condition.StringEquals["aws:ResourceTag/Purpose"], "") == "ebs-package-collector"
    error_message = "Snapshot read/delete must stay conditioned on aws:ResourceTag/Purpose."
  }

  assert {
    condition = try([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement :
      s if s.Sid == "CreateTaggedSnapshot"
    ][0].Condition.StringEquals["aws:RequestTag/Purpose"], "") == "ebs-package-collector"
    error_message = "CreateSnapshot must be gated on aws:RequestTag/Purpose, not ResourceTag."
  }

  assert {
    condition = try([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement :
      s if s.Sid == "TagSnapshotsAtCreate"
    ][0].Condition.StringEquals["ec2:CreateAction"], "") == "CreateSnapshot"
    error_message = "ec2:CreateTags must be gated on ec2:CreateAction = CreateSnapshot."
  }

  # The account field is deliberately EMPTY here; pinning it made every
  # CreateSnapshot fail with UnauthorizedOperation, verified against real AWS.
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement :
      length(regexall("^arn:aws:ec2:us-east-1::snapshot/\\*$", tostring(s.Resource))) > 0
      if s.Sid == "CreateTaggedSnapshot" || s.Sid == "ReadAndDeleteOwnSnapshots"
    ])
    error_message = "Snapshot ARNs must be region-scoped with an empty account field."
  }
}

# The other run reading the launcher policies filters on ecs:RunTask, which
# excludes the PassRole statement in the same shared local.
run "pass_role_stays_scoped_and_confined_to_ecs" {
  command = apply

  # Presence FIRST: everything below filters on iam:PassRole, and a filter that
  # matches nothing yields alltrue([]) == true, so a deleted grant stays green.
  assert {
    condition = length(flatten([
      for policy in [
        aws_iam_role_policy.orchestrator.policy,
        aws_iam_role_policy.events.policy,
        aws_iam_role_policy.initial_scan[0].policy,
        ] : [
        for s in jsondecode(policy).Statement : s if contains(flatten([s.Action]), "iam:PassRole")
      ]
    ])) == 3
    error_message = "All three launcher policies must carry an iam:PassRole grant."
  }

  assert {
    condition = alltrue([
      for policy in [
        aws_iam_role_policy.orchestrator.policy,
        aws_iam_role_policy.events.policy,
        aws_iam_role_policy.initial_scan[0].policy,
        ] : alltrue([
          for s in jsondecode(policy).Statement :
          try(s.Condition.StringEquals["iam:PassedToService"], "") == "ecs-tasks.amazonaws.com"
          && toset(s.Resource) == toset([aws_iam_role.task.arn, aws_iam_role.execution.arn])
          if contains(flatten([s.Action]), "iam:PassRole")
      ])
    ])
    error_message = "iam:PassRole must be confined to ecs-tasks.amazonaws.com and the two scanner roles."
  }
}

# These four are deliberate decisions the module documents but nothing asserted:
# a mutation sweep flipped each one and the suite stayed green.
run "deliberate_decisions_stay_put" {
  command = plan

  variables {
    schedule_enabled = false
  }

  assert {
    condition     = aws_cloudwatch_event_rule.daily.state == "DISABLED"
    error_message = "schedule_enabled = false must disable the rule."
  }
}

run "schedule_is_enabled_by_default" {
  command = plan

  assert {
    condition     = aws_cloudwatch_event_rule.daily.state == "ENABLED"
    error_message = "The daily rule must be ENABLED by default."
  }

  assert {
    condition     = aws_ecs_task_definition.this.skip_destroy == true
    error_message = "skip_destroy must stay true — every task-definition attribute is ForceNew, so without it an apply deregisters the family's only ACTIVE revision."
  }

  assert {
    condition     = length(aws_lambda_function.initial_scan[0].environment[0].variables) == 4
    error_message = "The initial-scan Lambda's four env vars are its whole contract with initial_scan.py; a missing one is a KeyError that silently skips the first scan."
  }

  assert {
    condition = toset(keys(aws_lambda_function.initial_scan[0].environment[0].variables)) == toset([
      "CLUSTER_ARN", "TASK_DEF_ARN", "SUBNET_IDS", "SECURITY_GROUP_ID"
    ])
    error_message = "initial_scan.py reads exactly these four env vars by name."
  }
}

run "kms_grants_are_present_by_default" {
  command = plan

  assert {
    condition = contains(
      [for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Sid],
      "ReadEncryptedVolumes"
    )
    error_message = "The ReadEncryptedVolumes KMS grant must be present by default."
  }
}

run "kms_grants_can_be_dropped" {
  command = plan

  variables {
    scan_encrypted_volumes = false
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement :
      s if startswith(s.Sid, "ReadEncryptedVolumes") || startswith(s.Sid, "GrantEC2")
    ]) == 0
    error_message = "scan_encrypted_volumes = false must remove the KMS statements."
  }
}

run "kms_grants_can_be_scoped_to_named_keys" {
  command = plan

  variables {
    kms_key_arns = ["arn:aws:kms:us-east-1:111111111111:key/abcd"]
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement :
      s if startswith(s.Sid, "ReadEncryptedVolumes")
    ]) == 1
    error_message = "The KMS statement vanished when kms_key_arns was set."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement :
      s.Resource == ["arn:aws:kms:us-east-1:111111111111:key/abcd"]
      if startswith(s.Sid, "ReadEncryptedVolumes") || startswith(s.Sid, "GrantEC2")
    ])
    error_message = "kms_key_arns must narrow the KMS grants to the supplied keys."
  }
}

# Caught by the variable's own validation, which names the offending input.
run "whitespace_only_customer_id_is_rejected" {
  command = plan

  variables {
    customer_id = "   "
  }

  expect_failures = [var.customer_id]
}

run "whitespace_only_tenant_name_is_rejected" {
  command = plan

  variables {
    tenant_name = "  "
  }

  expect_failures = [var.tenant_name]
}

run "customer_id_is_trimmed" {
  command = apply

  variables {
    customer_id = "  customer-abc\n"
  }

  assert {
    condition = alltrue([
      for pair in ["COLLECTOR_CUSTOMER_ID=customer-abc", "COLLECTOR_STREAM_SCAN_WORKSPACE=customer-abc"] :
      contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], pair)
    ])
    error_message = "customer_id must be trimmed before it reaches the container."
  }
}

run "oversized_vpc_cidr_is_rejected" {
  command = plan

  variables {
    scanner_vpc_cidr = "10.0.0.0/8"
  }

  expect_failures = [var.scanner_vpc_cidr]
}

run "invalid_fargate_cpu_is_rejected" {
  command = plan

  variables {
    task_cpu = "3000"
  }

  expect_failures = [var.task_cpu]
}

# Fargate accepts only 512, 1024 and 2048 MiB at 256 CPU — the one irregular row;
# modelling it as a 512 MiB step let 1536 through to fail mid-apply.
run "irregular_fargate_256_row_rejects_1536" {
  command = plan

  variables {
    task_cpu    = "256"
    task_memory = "1536"
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "valid_fargate_256_pair_is_accepted" {
  command = plan

  variables {
    task_cpu    = "256"
    task_memory = "2048"
  }

  assert {
    condition     = aws_ecs_task_definition.this.memory == "2048"
    error_message = "256/2048 is a valid Fargate pair and must be accepted."
  }
}

run "invalid_secret_recovery_window_is_rejected" {
  command = plan

  variables {
    secret_recovery_window_days = 3
  }

  expect_failures = [var.secret_recovery_window_days]
}

run "tenant_name_can_be_overridden" {
  command = apply

  variables {
    tenant_name = "acme-prod"
  }

  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], "COLLECTOR_TENANT_NAME=acme-prod")
    error_message = "tenant_name must override the value derived from the host URL."
  }
}

run "oversized_resource_prefix_is_rejected" {
  command = plan

  variables {
    resource_prefix = "acme-production-platform"
  }

  expect_failures = [var.resource_prefix]
}

run "too_small_a_vpc_cidr_is_rejected" {
  command = plan

  variables {
    scanner_vpc_cidr = "10.255.0.0/28"
  }

  expect_failures = [var.scanner_vpc_cidr]
}

run "rate_schedule_is_rejected" {
  command = plan

  variables {
    schedule_expression = "rate(24 hours)"
  }

  expect_failures = [var.schedule_expression]
}
