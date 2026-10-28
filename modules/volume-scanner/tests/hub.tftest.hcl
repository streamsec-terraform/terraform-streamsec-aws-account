# NOTE: `terraform test` on this file needs Terraform >= 1.7 (mock_provider),
# stricter than the module's own required_version. Plan/apply is unaffected.

# Parity with the console's CloudFormation scanner stack: the hub grant, the
# reaper, Spot workers with a small orchestrator, and the install acknowledgement.

mock_provider "aws" {
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111111111111:cluster/streamsec-ebs-scanner-tf-us-east-1" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111111111111:task-definition/streamsec-ebs-scanner-tf:7" }
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

# mock_resource defaults apply to every resource of a type, so both task
# definitions and all four roles would share one ARN and a swapped reference
# would still pass. Give each sibling its own.
override_resource {
  target = aws_ecs_task_definition.worker
  values = { arn = "arn:aws:ecs:us-east-1:111111111111:task-definition/streamsec-ebs-scanner-tf-worker:3" }
}

override_resource {
  target = aws_iam_role.task
  values = { arn = "arn:aws:iam::111111111111:role/streamsec-ebs-scanner-tf-us-east-1-task-role" }
}

override_resource {
  target = aws_iam_role.execution
  values = { arn = "arn:aws:iam::111111111111:role/streamsec-ebs-scanner-tf-us-east-1-execution-role" }
}

mock_provider "streamsec" {
  mock_data "streamsec_host" {
    defaults = { url = "https://acme.streamsec.io" }
  }
  mock_data "streamsec_aws_account" {
    defaults = {
      id                         = "stream-account-1"
      cloud_account_id           = "111111111111"
      streamsec_collection_token = "collection-token"
    }
  }
}

mock_provider "archive" {}

variables {
  customer_id = "customer-abc"
}

################################################################################
# The hub grant
################################################################################

run "task_role_can_assume_every_spoke_access_role" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s if try(s.Sid, "") == "AssumeSpokeAccessRoles"
    ]) == 1
    error_message = "The task role policy must carry exactly one AssumeSpokeAccessRoles statement."
  }

  # Statement for statement with the CloudFormation stack: no condition, any
  # account, the access stack's fixed role name.
  assert {
    condition = jsonencode([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s if try(s.Sid, "") == "AssumeSpokeAccessRoles"
      ][0]) == jsonencode({
      Sid      = "AssumeSpokeAccessRoles"
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = "arn:aws:iam::*:role/StreamScannerSpokeRole"
    })
    error_message = "AssumeSpokeAccessRoles must be sts:AssumeRole on arn:<partition>:iam::*:role/StreamScannerSpokeRole, as in the CloudFormation stack."
  }
}

# Always granted, as in the CloudFormation stack: nothing gates it.
run "spoke_grant_survives_every_option_turned_off" {
  command = plan

  variables {
    workload_kinds         = ""
    scan_encrypted_volumes = false
    trigger_initial_scan   = false
    schedule_enabled       = false
  }

  assert {
    condition = contains([
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : try(s.Resource, "") if try(s.Sid, "") == "AssumeSpokeAccessRoles"
    ], "arn:aws:iam::*:role/StreamScannerSpokeRole")
    error_message = "AssumeSpokeAccessRoles must not depend on any input."
  }
}

run "spoke_grant_is_partition_aware" {
  command = plan

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
      for s in jsondecode(aws_iam_role_policy.task.policy).Statement : s.Resource if try(s.Sid, "") == "AssumeSpokeAccessRoles"
    ] == ["arn:aws-cn:iam::*:role/StreamScannerSpokeRole"]
    error_message = "In aws-cn the spoke role ARN must use the aws-cn partition."
  }
}

# The spoke role trusts this role by name (aws:PrincipalArn StringLike
# arn:<p>:iam::<hub>:role/*streamsec-ebs-scanner-tf-*). A rename here would
# lock every spoke out with the suite otherwise green.
run "task_role_name_matches_the_spoke_trust_pattern" {
  command = plan

  assert {
    condition     = length(regexall("^[A-Za-z0-9+=,.@_-]*streamsec-ebs-scanner-tf-.*$", aws_iam_role.task.name)) == 1
    error_message = "The task role name must match the spoke trust pattern *streamsec-ebs-scanner-tf-*."
  }

  assert {
    condition     = aws_iam_role.task.path == "/" || aws_iam_role.task.path == null
    error_message = "A role path becomes part of the principal ARN; the spoke trust pattern assumes none."
  }
}

run "prefixed_task_role_name_still_matches_the_spoke_trust_pattern" {
  command = plan

  variables {
    resource_prefix = "acme-prd"
  }

  assert {
    condition     = length(regexall("^[A-Za-z0-9+=,.@_-]*streamsec-ebs-scanner-tf-.*$", aws_iam_role.task.name)) == 1 && startswith(aws_iam_role.task.name, "acme-prd-")
    error_message = "resource_prefix must keep the task role inside the spoke trust pattern."
  }
}

################################################################################
# The reaper
################################################################################

run "reaper_lists_and_stops_tasks_in_its_own_cluster_only" {
  command = apply

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.orchestrator.policy).Statement : s if try(s.Sid, "") == "OrchestratorStopStuckTasks"
    ]) == 1
    error_message = "The orchestrator policy must carry exactly one OrchestratorStopStuckTasks statement."
  }

  assert {
    condition = jsonencode([
      for s in jsondecode(aws_iam_role_policy.orchestrator.policy).Statement : s if try(s.Sid, "") == "OrchestratorStopStuckTasks"
      ][0]) == jsonencode({
      Sid       = "OrchestratorStopStuckTasks"
      Effect    = "Allow"
      Action    = ["ecs:ListTasks", "ecs:StopTask"]
      Resource  = "*"
      Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
    })
    error_message = "The reaper grant must be ecs:ListTasks + ecs:StopTask on *, conditioned on this cluster, as in the CloudFormation stack."
  }

  # StopTask nowhere else: not account-wide, and on no other role.
  assert {
    condition = length(flatten([
      for policy in [
        aws_iam_role_policy.task.policy,
        aws_iam_role_policy.orchestrator.policy,
        aws_iam_role_policy.events.policy,
        aws_iam_role_policy.initial_scan[0].policy,
        aws_iam_role_policy.execution_secrets.policy,
        ] : [
        for s in jsondecode(policy).Statement : s if contains(flatten([s.Action]), "ecs:StopTask")
      ]
    ])) == 1
    error_message = "ecs:StopTask must be granted exactly once, in the reaper statement."
  }
}

################################################################################
# A small orchestrator, full-size workers on Spot
################################################################################

run "task_definitions_have_the_cloudformation_sizes" {
  command = plan

  assert {
    condition     = aws_ecs_task_definition.this.cpu == "512" && aws_ecs_task_definition.this.memory == "1024"
    error_message = "The orchestrator must run at 512 CPU / 1024 MiB, the CloudFormation stack's Orchestrator size."
  }

  assert {
    condition     = length(aws_ecs_task_definition.this.ephemeral_storage) == 0
    error_message = "The orchestrator takes Fargate's default storage; it holds no disk cache."
  }

  assert {
    condition     = aws_ecs_task_definition.worker.cpu == "4096" && aws_ecs_task_definition.worker.memory == "16384"
    error_message = "The worker must default to 4096 CPU / 16384 MiB, the CloudFormation stack's Worker size."
  }

  assert {
    condition     = aws_ecs_task_definition.worker.ephemeral_storage[0].size_in_gib == 50
    error_message = "The worker keeps the 50 GiB disk cache."
  }

  assert {
    condition = alltrue([
      aws_ecs_task_definition.this.family == "streamsec-ebs-scanner-tf",
      aws_ecs_task_definition.worker.family == "streamsec-ebs-scanner-tf-worker",
    ])
    error_message = "Families must be streamsec-ebs-scanner-tf (orchestrator, unchanged) and streamsec-ebs-scanner-tf-worker."
  }

  assert {
    condition = alltrue([
      for td in [aws_ecs_task_definition.this, aws_ecs_task_definition.worker] :
      td.network_mode == "awsvpc" && toset(td.requires_compatibilities) == toset(["FARGATE"])
    ])
    error_message = "Both task definitions must be awsvpc Fargate."
  }
}

# The existing sizing inputs keep working: they size the worker now.
run "sizing_inputs_size_the_worker_not_the_orchestrator" {
  command = plan

  variables {
    task_cpu                   = "8192"
    task_memory                = "32768"
    ephemeral_storage_size_gib = 100
  }

  assert {
    condition = alltrue([
      aws_ecs_task_definition.worker.cpu == "8192",
      aws_ecs_task_definition.worker.memory == "32768",
      aws_ecs_task_definition.worker.ephemeral_storage[0].size_in_gib == 100,
    ])
    error_message = "task_cpu, task_memory and ephemeral_storage_size_gib must size the worker."
  }

  assert {
    condition     = aws_ecs_task_definition.this.cpu == "512" && aws_ecs_task_definition.this.memory == "1024"
    error_message = "The orchestrator stays at 512 / 1024 whatever the worker size."
  }
}

run "both_task_definitions_run_as_the_scanner_roles" {
  command = apply

  assert {
    condition = alltrue([
      for td in [aws_ecs_task_definition.this, aws_ecs_task_definition.worker] :
      td.task_role_arn == aws_iam_role.task.arn && td.execution_role_arn == aws_iam_role.execution.arn
    ])
    error_message = "Orchestrator and worker must both run as the task role, with the execution role."
  }
}

run "orchestrator_and_worker_environments_are_wired_to_each_other" {
  command = apply

  assert {
    condition = alltrue([
      for pair in [
        "COLLECTOR_ROLE=orchestrator",
        "COLLECTOR_ECS_TASK_DEF_ARN=arn:aws:ecs:us-east-1:111111111111:task-definition/streamsec-ebs-scanner-tf-worker",
        "COLLECTOR_ECS_CAPACITY_PROVIDER=FARGATE_SPOT",
        "COLLECTOR_ECS_RETRY_CPU=4096",
        "COLLECTOR_ECS_RETRY_MEMORY=16384",
      ] :
      contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], pair)
    ])
    error_message = "The orchestrator must launch workers from the revision-less worker family, first on FARGATE_SPOT, retries at 4096/16384."
  }

  assert {
    condition = alltrue([
      for pair in [
        "COLLECTOR_ROLE=worker",
        "COLLECTOR_ECS_TASK_DEF_ARN=arn:aws:ecs:us-east-1:111111111111:task-definition/streamsec-ebs-scanner-tf",
        "COLLECTOR_ECS_CAPACITY_PROVIDER=FARGATE_SPOT",
        "COLLECTOR_ECS_RETRY_CPU=4096",
        "COLLECTOR_ECS_RETRY_MEMORY=16384",
      ] :
      contains([for e in jsondecode(aws_ecs_task_definition.worker.container_definitions)[0].environment : "${e.name}=${e.value}"], pair)
    ])
    error_message = "The worker's COLLECTOR_ECS_TASK_DEF_ARN must be the revision-less orchestrator family, with the same Spot and retry env."
  }

  # One environment, two renderings: only the role and the task definition
  # named differ, so a setting cannot reach one and miss the other.
  assert {
    condition = toset(setsubtract(
      [for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"],
      [for e in jsondecode(aws_ecs_task_definition.worker.container_definitions)[0].environment : "${e.name}=${e.value}"],
      )) == toset([
      "COLLECTOR_ROLE=orchestrator",
      "COLLECTOR_ECS_TASK_DEF_ARN=arn:aws:ecs:us-east-1:111111111111:task-definition/streamsec-ebs-scanner-tf-worker",
    ])
    error_message = "Orchestrator and worker environments may differ only in COLLECTOR_ROLE and COLLECTOR_ECS_TASK_DEF_ARN."
  }

  assert {
    condition = length(jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment) == length(
      jsondecode(aws_ecs_task_definition.worker.container_definitions)[0].environment
    )
    error_message = "Orchestrator and worker must carry the same environment variables."
  }

  # The worker's COLLECTOR_ECS_TASK_DEF_ARN is the ECS workload discoverer's
  # self-skip PREFIX: it must prefix a revision ARN of both families the module
  # registers, or the workload child scans the scanner's own tasks.
  assert {
    condition = alltrue([
      for family in [aws_ecs_task_definition.this.family, aws_ecs_task_definition.worker.family] :
      startswith("arn:aws:ecs:us-east-1:111111111111:task-definition/${family}:1", one([
        for e in jsondecode(aws_ecs_task_definition.worker.container_definitions)[0].environment : e.value if e.name == "COLLECTOR_ECS_TASK_DEF_ARN"
      ]))
    ])
    error_message = "The worker's self-skip prefix must cover both families the module registers."
  }

  # And the orchestrator launches the family the module actually registers.
  assert {
    condition = one([
      for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.value if e.name == "COLLECTOR_ECS_TASK_DEF_ARN"
    ]) == "arn:aws:ecs:us-east-1:111111111111:task-definition/${aws_ecs_task_definition.worker.family}"
    error_message = "The orchestrator must launch workers from the worker task definition's own family."
  }

  assert {
    condition = alltrue([
      for td in [aws_ecs_task_definition.this, aws_ecs_task_definition.worker] :
      jsondecode(td.container_definitions)[0].secrets == [{ name = "COLLECTOR_STREAM_SCAN_TOKEN", valueFrom = aws_secretsmanager_secret.collection_token.arn }]
    ])
    error_message = "Both containers must take the collection token from this module's secret."
  }
}

# A Spot interruption gives two minutes' notice: time for the worker's report.
run "only_the_worker_has_the_spot_stop_timeout" {
  command = apply

  assert {
    condition     = jsondecode(aws_ecs_task_definition.worker.container_definitions)[0].stopTimeout == 120
    error_message = "The worker container must have stopTimeout 120, as in the CloudFormation stack."
  }

  assert {
    condition     = try(jsondecode(aws_ecs_task_definition.this.container_definitions)[0].stopTimeout, null) == null
    error_message = "The orchestrator runs on-demand and has no stopTimeout."
  }
}

# Retry is never smaller than the worker: a shard that ran out of memory
# must not be retried on less (the CloudFormation stack's "keep Retry at least Worker").
run "retry_size_grows_with_a_larger_worker" {
  command = apply

  variables {
    task_cpu    = "8192"
    task_memory = "32768"
  }

  assert {
    condition = alltrue([
      for pair in ["COLLECTOR_ECS_RETRY_CPU=8192", "COLLECTOR_ECS_RETRY_MEMORY=32768"] :
      contains([for e in jsondecode(aws_ecs_task_definition.worker.container_definitions)[0].environment : "${e.name}=${e.value}"], pair)
    ])
    error_message = "A worker larger than 4096/16384 must be retried at its own size."
  }
}

# Smaller than the floor on both CPU and memory, so each floor is exercised.
run "retry_size_keeps_the_cloudformation_floor_for_a_smaller_worker" {
  command = apply

  variables {
    task_cpu    = "2048"
    task_memory = "8192"
  }

  assert {
    condition = alltrue([
      for pair in ["COLLECTOR_ECS_RETRY_CPU=4096", "COLLECTOR_ECS_RETRY_MEMORY=16384"] :
      contains([for e in jsondecode(aws_ecs_task_definition.worker.container_definitions)[0].environment : "${e.name}=${e.value}"], pair)
    ])
    error_message = "A worker smaller than 4096/16384 must be retried at the CloudFormation Retry size."
  }
}

# Full CPU but less memory: the worker is not at least the floor on both, so the
# retry takes the floor rather than the worker's 8192 MiB.
run "retry_size_takes_the_floor_when_only_memory_is_smaller" {
  command = apply

  variables {
    task_cpu    = "4096"
    task_memory = "8192"
  }

  assert {
    condition = alltrue([
      for pair in ["COLLECTOR_ECS_RETRY_CPU=4096", "COLLECTOR_ECS_RETRY_MEMORY=16384"] :
      contains([for e in jsondecode(aws_ecs_task_definition.worker.container_definitions)[0].environment : "${e.name}=${e.value}"], pair)
    ])
    error_message = "A worker with less than 16384 MiB must be retried at 4096 / 16384."
  }
}

run "cluster_offers_fargate_and_fargate_spot" {
  command = apply

  assert {
    condition     = aws_ecs_cluster_capacity_providers.this.cluster_name == aws_ecs_cluster.this.name
    error_message = "The capacity providers must be attached to the scanner's own cluster."
  }

  assert {
    condition     = toset(aws_ecs_cluster_capacity_providers.this.capacity_providers) == toset(["FARGATE", "FARGATE_SPOT"])
    error_message = "The cluster must offer FARGATE and FARGATE_SPOT, as in the CloudFormation stack."
  }

  # The orchestrator and the schedule pass launch type FARGATE; a default
  # strategy would only matter to a launch that names none.
  assert {
    condition     = length(aws_ecs_cluster_capacity_providers.this.default_capacity_provider_strategy) == 0
    error_message = "The CloudFormation stack sets no default capacity provider strategy."
  }
}

################################################################################
# Who launches what
################################################################################

run "orchestrator_launches_only_the_worker_family" {
  command = apply

  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.orchestrator.policy).Statement :
      flatten([s.Resource]) if contains(flatten([s.Action]), "ecs:RunTask")
      ])) == toset([
      "arn:aws:ecs:us-east-1:111111111111:task-definition/streamsec-ebs-scanner-tf-worker",
      "arn:aws:ecs:us-east-1:111111111111:task-definition/streamsec-ebs-scanner-tf-worker:*",
    ])
    error_message = "The orchestrator's RunTask must cover the worker family (and every revision of it) and nothing else."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.orchestrator.policy).Statement :
      try(s.Condition.ArnEquals["ecs:cluster"], "") == aws_ecs_cluster.this.arn
      if contains(flatten([s.Action]), "ecs:RunTask")
    ])
    error_message = "The orchestrator's RunTask must be conditioned on the scanner cluster."
  }
}

run "schedule_and_initial_scan_launch_the_orchestrator" {
  command = apply

  assert {
    condition     = aws_cloudwatch_event_target.daily.ecs_target[0].task_definition_arn == aws_ecs_task_definition.this.arn
    error_message = "The schedule must start the orchestrator task definition."
  }

  assert {
    condition     = aws_lambda_function.initial_scan[0].environment[0].variables["TASK_DEF_ARN"] == aws_ecs_task_definition.this.arn
    error_message = "The initial scan must start the orchestrator task definition."
  }

  assert {
    condition = alltrue([
      for policy in [aws_iam_role_policy.events.policy, aws_iam_role_policy.initial_scan[0].policy] :
      flatten([for s in jsondecode(policy).Statement : flatten([s.Resource]) if contains(flatten([s.Action]), "ecs:RunTask")]) == [aws_ecs_task_definition.this.arn]
    ])
    error_message = "EventBridge and the initial scan may run only the orchestrator revision."
  }

  # Both launchers pass the two scanner roles, which both families run as.
  assert {
    condition = alltrue([
      for policy in [
        aws_iam_role_policy.orchestrator.policy,
        aws_iam_role_policy.events.policy,
        aws_iam_role_policy.initial_scan[0].policy,
        ] : toset(flatten([
          for s in jsondecode(policy).Statement : flatten([s.Resource]) if contains(flatten([s.Action]), "iam:PassRole")
      ])) == toset([aws_iam_role.task.arn, aws_iam_role.execution.arn])
    ])
    error_message = "Every launcher must pass exactly the task and execution roles."
  }
}

################################################################################
# Install acknowledgement
################################################################################

run "install_is_acknowledged_with_the_module_version" {
  command = apply

  assert {
    condition = alltrue([
      streamsec_aws_volume_scanner_ack.this.account_id == "stream-account-1",
      streamsec_aws_volume_scanner_ack.this.region == "us-east-1",
    ])
    error_message = "The acknowledgement must name this account's Stream id and the scanned region."
  }

  # The release this module is tagged as, with no leading v. Bump it here and in
  # local.module_version together.
  assert {
    condition     = streamsec_aws_volume_scanner_ack.this.module_version == "1.16.0"
    error_message = "The acknowledgement must report the module's release version, 1.16.0."
  }
}
