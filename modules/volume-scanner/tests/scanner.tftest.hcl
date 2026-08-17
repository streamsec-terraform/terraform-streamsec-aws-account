# NOTE: running these tests requires Terraform >= 1.7 (mock_provider blocks) —
# stricter than the module's own required_version. Older versions fail to parse
# this file when running `terraform test`; plan/apply of the module itself is
# unaffected, tests/ is ignored there.

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
    error_message = "Default feature toggles and scaling knobs must match the CloudFormation template: only language packages on, lambda+ecs workloads, 100-instance shards, 10 concurrent."
  }

  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], "COLLECTOR_TENANT_NAME=acme")
    error_message = "The tenant name must be derived from the first label of the Stream host URL."
  }

  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], "COLLECTOR_STREAM_SCAN_URL=https://acme.streamsec.io/openapi/vulnerabilities/stream_scan/raw")
    error_message = "The SBOM ingest URL must be the tenant host plus the stream_scan/raw path."
  }

  assert {
    condition = alltrue([
      for pair in ["COLLECTOR_CUSTOMER_ID=customer-abc", "COLLECTOR_STREAM_SCAN_WORKSPACE=customer-abc"] :
      contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], pair)
    ])
    error_message = "Both the customer id and the scan workspace must carry the configured customer_id."
  }

  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], "COLLECTOR_ECS_TASK_DEF_ARN=arn:aws:ecs:us-east-1:111111111111:task-definition/streamsec-ebs-scanner-tf")
    error_message = "The orchestrator must receive a revision-less family ARN, so child tasks always launch on the current ACTIVE revision."
  }
}

# The container used to receive var.workload_kinds verbatim while IAM was built
# from the trimmed list, so "lambda, ecs" granted the ECS statements and then sent
# " ecs" to the scanner, which matches no kind — workload scanning silently did
# nothing with the grants still attached.
run "workload_kinds_reach_the_container_normalized" {
  command = apply

  variables {
    workload_kinds = "ecs, lambda"
  }

  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], "COLLECTOR_WORKLOAD_KINDS=ecs,lambda")
    error_message = "COLLECTOR_WORKLOAD_KINDS must be the trimmed, normalized list — the raw value reaches the scanner's comma split and a padded element matches no kind."
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
    error_message = "Every scanner toggle and scaling knob must be plumbed through to the container environment."
  }
}

run "task_sizing_matches_the_cloudformation_template" {
  command = plan

  assert {
    condition     = aws_ecs_task_definition.this.cpu == "4096" && aws_ecs_task_definition.this.memory == "16384"
    error_message = "Default task sizing must stay at the 4 vCPU / 16 GB profile sized for 10 concurrent shards."
  }

  assert {
    condition     = aws_ecs_task_definition.this.ephemeral_storage[0].size_in_gib == 50
    error_message = "Ephemeral storage must default to 50 GiB for the L2 disk cache."
  }

  assert {
    condition     = aws_ecs_task_definition.this.family == "streamsec-ebs-scanner-tf"
    error_message = "The task definition family must stay \"streamsec-ebs-scanner-tf\" — deliberately NOT the CloudFormation template's \"streamsec-ebs-scanner\", so a Terraform revision can never be registered into the family the CloudFormation orchestrator launches from."
  }
}

run "schedule_uses_cron_not_rate" {
  command = plan

  assert {
    condition     = aws_cloudwatch_event_rule.daily.schedule_expression == "cron(0 3 * * ? *)"
    error_message = "The schedule must be a cron expression: a rate(...) rule fires once at creation as well as on the interval, duplicating the first scan."
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
    error_message = "trigger_initial_scan = false must drop the Lambda, its invocation and its IAM role."
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
    error_message = "By default the module must fire one immediate scan, matching the CloudFormation InitialScanTrigger."
  }
}

run "resource_prefix_is_applied" {
  command = plan

  variables {
    resource_prefix = "acme"
  }

  assert {
    condition     = aws_ecs_cluster.this.name == "acme-streamsec-ebs-scanner-tf-us-east-1"
    error_message = "resource_prefix must prefix the resource names, and names must carry the region so two regions in one account do not collide."
  }

  # startswith, not equality: the name carries a random suffix so that
  # destroy-then-apply works with a non-zero secret_recovery_window_days.
  assert {
    condition     = startswith(aws_secretsmanager_secret.collection_token.name, "acme-streamsec-scanner-collection-token-us-east-1-")
    error_message = "The Secrets Manager secret must carry resource_prefix too — without it two prefixed deployments in one account/region collide on the same secret name."
  }

  assert {
    condition     = length(aws_secretsmanager_secret.collection_token.name) > length("acme-streamsec-scanner-collection-token-us-east-1-")
    error_message = "The secret name must end in a random suffix, or a non-zero secret_recovery_window_days blocks destroy-then-apply for the whole window."
  }
}

# The module must refuse to sit alongside the console's CloudFormation scanner:
# both would scan every volume, and each one's retention sweep deletes snapshots
# tagged Purpose=ebs-package-collector account-wide — including the other's.
run "refuses_to_deploy_alongside_the_cloudformation_scanner" {
  command = plan

  override_data {
    target = data.aws_ecs_clusters.existing
    values = {
      cluster_arns = ["arn:aws:ecs:us-east-1:111111111111:cluster/streamsec-ebs-scanner-us-east-1"]
    }
  }

  # Both, not just the cluster. The VPC carries the same guard because it has no
  # dependency on the cluster and would otherwise be created in parallel — and
  # left behind billing — when the cluster's check trips. The Elastic IP and NAT
  # gateway are downstream of the VPC, so they are covered by its failure.
  # The three resources the gate is placed on: the VPC because it and the NAT
  # gateway downstream of it cost money, the cluster because an identically named
  # one can be silently adopted, and the secret because it persists the account's
  # Stream collection token. The IAM roles and log groups may still be created,
  # but they are inert and recorded in state, so a destroy removes them.
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
    error_message = "allow_cloudformation_coexistence must permit the deploy, and the module's own cluster name must stay distinct from the CloudFormation stack's."
  }
}

# The module's own cluster must never be mistaken for the CloudFormation one, or
# every re-apply would trip the guard.
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
    error_message = "The presence check must match the CloudFormation name exactly; our own -tf cluster must not look like a collision."
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
    error_message = "Cluster, task-definition family and log group must all differ from the CloudFormation stack's hardcoded names — ecs:CreateCluster is an upsert, so an identical cluster name is silently adopted rather than rejected."
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
    error_message = "A region with no existing ECS clusters must plan cleanly — cluster_arns is null there, not an empty list."
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
    error_message = "The collection token must never appear as a plaintext environment variable — it would be printed in plan output, stored unredacted in state, and readable by anything holding ecs:DescribeTaskDefinition."
  }

  assert {
    condition = length([
      for s in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets :
      s if s.name == "COLLECTOR_STREAM_SCAN_TOKEN" && s.valueFrom == aws_secretsmanager_secret.collection_token.arn
    ]) == 1
    error_message = "The collection token must be injected via the task definition's secrets block, sourced from the module's Secrets Manager secret."
  }

  assert {
    condition = contains(
      jsondecode(aws_iam_role_policy.execution_secrets.policy).Statement[0].Action,
      "secretsmanager:GetSecretValue"
    )
    error_message = "ECS resolves the secrets block with the execution role, so that role must be able to read the secret."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.execution_secrets.policy).Statement[0].Resource == aws_secretsmanager_secret.collection_token.arn
    error_message = "The GetSecretValue grant must be scoped to this module's own collection-token secret, never \"*\" — the execution role would otherwise read every secret in the account."
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
    error_message = "workload_kinds = \"\" is documented as disabling workload scanning entirely, so the account-wide Lambda/ECS/ECR grants must not be attached."
  }
}

run "workload_iam_is_present_by_default" {
  command = plan

  assert {
    condition = alltrue([
      for sid in ["WorkloadLambdaList", "WorkloadLambdaGet", "WorkloadEcsDiscovery", "WorkloadImageAuth", "WorkloadImagePull"] :
      contains([for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Sid], sid)
    ])
    error_message = "With the default workload_kinds (lambda,ecs) every workload-scanning statement must be granted."
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
    error_message = "workload_kinds = \"lambda\" must not grant account-wide ECS task and task-definition read access."
  }

  assert {
    condition = alltrue([
      for sid in ["WorkloadLambdaList", "WorkloadLambdaGet", "WorkloadImageAuth", "WorkloadImagePull"] :
      contains([for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Sid], sid)
    ])
    error_message = "workload_kinds = \"lambda\" must still grant the Lambda statements and the shared ECR image-pull statements."
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
    error_message = "workload_kinds = \"ecs\" must not grant account-wide lambda:GetFunction, which downloads function code."
  }

  assert {
    condition = alltrue([
      for sid in ["WorkloadEcsDiscovery", "WorkloadImageAuth", "WorkloadImagePull"] :
      contains([for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Sid], sid)
    ])
    error_message = "workload_kinds = \"ecs\" must still grant the ECS statements and the shared ECR image-pull statements."
  }
}

run "run_task_is_scoped_to_the_scanner_cluster" {
  command = apply

  # flatten() normalises `Action = "ecs:RunTask"` and `Action = ["ecs:RunTask"]`
  # to the same shape. Matching the bare string only — as this test first did —
  # made a pure-style change to a list silently empty the filter, and alltrue([])
  # is true, so the one test guarding "no role can launch the scanner task into
  # another cluster" would have gone permanently green while checking nothing.
  # flatten() around the OUTER list is the point. Without it, length() counts the
  # three inner lists — one per policy — and returns 3 no matter how many
  # statements matched, so deleting a RunTask grant entirely left this green.
  # Verified by deleting the events policy's statement: the suite now fails.
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
    error_message = "Expected exactly one ecs:RunTask statement in each of the three policies (orchestrator, events, initial scan). A missing one means a role lost its grant, or the filter stopped matching."
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
    error_message = "Every ecs:RunTask grant must be conditioned on the scanner's own cluster, or these roles could launch the task into any cluster in the account."
  }
}

# The duplicate-scan guard in initial_scan.py calls ecs:ListTasks. Nothing tested
# that the grant existed, so when it was added it landed on the EventBridge role
# instead and the guard stayed dead through a full review round.
run "initial_scan_role_can_check_for_a_running_scan" {
  command = apply

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.initial_scan[0].policy).Statement :
      s if contains(flatten([s.Action]), "ecs:ListTasks")
    ]) == 1
    error_message = "The initial-scan role must hold ecs:ListTasks, or the duplicate-scan guard is denied on every invocation, swallowed by its own except, and a second orchestrator snapshots every volume again."
  }

  # Asserted per ROLE, not per policy. The previous version filtered two of the
  # three policies attached to aws_iam_role.task and claimed no other role holds
  # ListTasks — while aws_iam_role_policy.task, on that same role, grants it
  # account-wide for ECS workload discovery. It stayed green by not looking.
  assert {
    condition = length([
      for s in concat(
        jsondecode(aws_iam_role_policy.events.policy).Statement,
      ) : s if contains(flatten([s.Action]), "ecs:ListTasks")
    ]) == 0
    error_message = "The EventBridge role never calls ListTasks, so granting it there is an unused permission."
  }

  # The scanner task role DOES hold account-wide ecs:ListTasks — workload
  # discovery needs it to enumerate tasks across every cluster — so it is asserted
  # as expected rather than absent, and disappears with workload scanning.
  assert {
    condition = length([
      for s in concat(
        jsondecode(aws_iam_role_policy.task.policy).Statement,
        jsondecode(aws_iam_role_policy.orchestrator.policy).Statement,
      ) : s if contains(flatten([s.Action]), "ecs:ListTasks")
    ]) == 1
    error_message = "With workload_kinds including ecs, the task role holds exactly one account-wide ecs:ListTasks for workload discovery. A second grant, or none, means the fan-out or the discovery pass changed."
  }
}

run "kms_grants_are_present_by_default" {
  command = plan

  assert {
    condition = alltrue([
      for sid in ["ReadEncryptedVolumes", "GrantEC2SnapshotAccessToKeys"] :
      contains([for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Sid], sid)
    ])
    error_message = "Without KMS grants the scanner snapshots an encrypted volume successfully and then fails every block read, reporting zero findings with no error — so they must be on by default."
  }

  assert {
    condition = try(jsondecode(aws_iam_role_policy.task.policy).Statement[
      index([for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Sid], "GrantEC2SnapshotAccessToKeys")
    ].Condition.Bool["kms:GrantIsForAWSResource"], null) == "true"
    error_message = "kms:CreateGrant must be conditioned on kms:GrantIsForAWSResource, so the role cannot mint grants of its own."
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
    error_message = "scan_encrypted_volumes = false must remove the KMS statements entirely, not merely stop using them."
  }
}

run "kms_grants_can_be_scoped_to_named_keys" {
  command = plan

  variables {
    kms_key_arns = ["arn:aws:kms:us-east-1:111111111111:key/abcd"]
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

# Now caught by the variable's own validation, which names the offending input
# instead of reporting a precondition failure against aws_ecs_task_definition
# after the whole graph has been evaluated.
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
    error_message = "A pasted workspace id with surrounding whitespace must be trimmed — shipping it verbatim tags every SBOM with a workspace that does not exist and ingest drops them silently."
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

# Fargate accepts only 512, 1024 and 2048 MiB at 256 CPU — the 256 row is the one
# irregular entry in the matrix, and modelling it as a 512 MiB step let 1536
# through to fail at RegisterTaskDefinition mid-apply.
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
    error_message = "tenant_name must override the value derived from the host URL, for tenants behind a shared endpoint, custom CNAME or PrivateLink DNS."
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
