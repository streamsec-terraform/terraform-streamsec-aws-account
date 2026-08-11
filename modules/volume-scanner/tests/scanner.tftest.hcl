# NOTE: running these tests requires Terraform >= 1.7 (mock_provider blocks) —
# stricter than the module's own required_version. Older versions fail to parse
# this file when running `terraform test`; plan/apply of the module itself is
# unaffected, tests/ is ignored there.

mock_provider "aws" {
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111111111111:cluster/mock-scanner" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111111111111:task-definition/streamsec-ebs-scanner:1" }
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
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], "COLLECTOR_ECS_TASK_DEF_ARN=arn:aws:ecs:us-east-1:111111111111:task-definition/streamsec-ebs-scanner")
    error_message = "The orchestrator must receive a revision-less family ARN, so child tasks always launch on the current ACTIVE revision."
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
    condition     = aws_ecs_task_definition.this.family == "streamsec-ebs-scanner"
    error_message = "The task definition family must match the CloudFormation template, so the orchestrator's family ARN resolves."
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
    condition     = aws_ecs_cluster.this.name == "acme-streamsec-ebs-scanner-us-east-1"
    error_message = "resource_prefix must prefix the resource names, and names must carry the region so two regions in one account do not collide."
  }

  assert {
    condition     = aws_secretsmanager_secret.collection_token.name == "acme-streamsec-scanner-collection-token-us-east-1"
    error_message = "The Secrets Manager secret must carry resource_prefix too — without it two prefixed deployments in one account/region collide on the same secret name."
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

  assert {
    condition = alltrue([
      for policy in [
        aws_iam_role_policy.orchestrator.policy,
        aws_iam_role_policy.events.policy,
        aws_iam_role_policy.initial_scan[0].policy,
        ] : alltrue([
          for s in jsondecode(policy).Statement :
          try(s.Condition.ArnEquals["ecs:cluster"], null) == aws_ecs_cluster.this.arn
          if s.Action == "ecs:RunTask"
      ])
    ])
    error_message = "Every ecs:RunTask grant must be conditioned on the scanner's own cluster, or these roles could launch the task into any cluster in the account."
  }
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
