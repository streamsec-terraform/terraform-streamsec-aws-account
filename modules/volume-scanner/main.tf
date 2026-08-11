data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "streamsec_host" "this" {}

data "streamsec_aws_account" "this" {
  cloud_account_id = data.aws_caller_identity.current.account_id
}

locals {
  name_prefix   = var.resource_prefix != "" ? "${var.resource_prefix}-" : ""
  name          = "${local.name_prefix}streamsec-ebs-scanner"
  region        = data.aws_region.current.region
  account_id    = data.aws_caller_identity.current.account_id
  partition     = data.aws_partition.current.partition
  regional_name = "${local.name}-${local.region}"

  api_url = trimsuffix(data.streamsec_host.this.url, "/")

  # The backend builds the tenant URL as https://{organization_name_prefix}.{domain},
  # so for a per-tenant hostname the first label is the tenant name. That does
  # not hold behind a shared/regional endpoint (app.streamsec.io), a custom
  # CNAME, or PrivateLink endpoint DNS — hence the var.tenant_name override.
  # Getting this wrong is silent: the scanner tags SBOMs with a tenant that does
  # not exist, ingest drops them, and the console still shows the region healthy.
  derived_tenant_name = split(".", replace(replace(local.api_url, "https://", ""), "http://", ""))[0]
  tenant_name         = var.tenant_name != null ? var.tenant_name : local.derived_tenant_name

  stream_scan_url = "${local.api_url}/openapi/vulnerabilities/stream_scan/raw"

  customer_id = var.customer_id == null ? "" : var.customer_id

  workload_kind_list    = [for kind in split(",", var.workload_kinds) : trimspace(kind) if trimspace(kind) != ""]
  scan_workloads        = length(local.workload_kind_list) > 0
  scan_lambda_workloads = contains(local.workload_kind_list, "lambda")
  scan_ecs_workloads    = contains(local.workload_kind_list, "ecs")

  tags = merge(var.tags, {
    "streamsec:component" = "ebs-scanner"
    "streamsec:customer"  = local.customer_id
    "streamsec:region"    = local.region
  })

  scanner_vpc_id     = var.create_scanner_vpc ? aws_vpc.this[0].id : var.vpc_id
  scanner_subnet_ids = var.create_scanner_vpc ? [aws_subnet.private[0].id] : var.subnet_ids

  scanner_public_subnet_cidr  = cidrsubnet(var.scanner_vpc_cidr, 1, 0)
  scanner_private_subnet_cidr = cidrsubnet(var.scanner_vpc_cidr, 1, 1)

  # Every Fargate task in awsvpc mode consumes one private IP, and AWS reserves
  # five addresses in each subnet. The orchestrator plus max_concurrent_shards
  # children all run at once, so the subnet has to hold them or the fan-out dies
  # part-way through with an opaque ENI-provisioning failure.
  scanner_private_subnet_capacity = pow(2, 32 - tonumber(split("/", local.scanner_private_subnet_cidr)[1])) - 5
  scanner_peak_task_count         = var.max_concurrent_shards + 1

  # Family ARN with no revision suffix, so the orchestrator's RunTask always
  # launches children on the current ACTIVE revision. Referencing the task
  # definition resource here would make it reference itself through its own
  # environment block.
  task_definition_family_arn = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:task-definition/${local.name}"

  # RunTask is authorized against the ARN the caller passes. The orchestrator
  # passes the revision-less family ARN while EventBridge and the initial-scan
  # Lambda pass a specific revision, so both forms have to be allowed. Scoping
  # to "<family>" plus "<family>:*" also keeps the three RunTask policies from
  # being rewritten on every task-definition revision.
  run_task_resources = [
    local.task_definition_family_arn,
    "${local.task_definition_family_arn}:*",
  ]

  # Bring-your-own-subnet mode is only active once both inputs are present;
  # the guard keeps the validation data sources from being read with a null
  # vpc_id, so a missing input surfaces as the precondition message in
  # network.tf rather than a provider error.
  byo_enabled  = !var.create_scanner_vpc && var.vpc_id != null && length(var.subnet_ids) > 0
  byo_validate = local.byo_enabled && var.validate_subnet_egress

  # Keyed by list INDEX, not by subnet id. for_each keys must be known at plan
  # time, and `subnet_ids = module.vpc.private_subnets` — the common wiring —
  # produces ids that are not known until apply. Indexes are known whenever the
  # list length is; unknown *values* are fine, and Terraform simply defers the
  # preconditions to apply. When even the length is unknown, set
  # validate_subnet_egress = false.
  #
  # validate_subnet_egress = false switches off BOTH supplied-subnet checks, the
  # wrong-VPC one included, not just the route walk. That is deliberate: the
  # escape hatch exists for subnet lists whose LENGTH is unknown at plan time,
  # and a for_each over such a list is rejected outright whichever check it
  # feeds. Splitting the two would leave the flag unable to do the one job it
  # was added for.
  byo_subnets = local.byo_validate ? { for index, subnet_id in var.subnet_ids : tostring(index) => subnet_id } : {}

  byo_wrong_vpc_subnets = [
    for subnet in data.aws_subnet.byo : subnet.id if subnet.vpc_id != var.vpc_id
  ]

  # Each subnet's effective route table. The explicit-association / main-route-table
  # fallback happens in the data source itself (see network.tf).
  byo_route_tables = data.aws_route_table.byo_explicit

  # Normalized to a "-" sentinel per target field. A route's unused target fields
  # come back as "" from some provider versions and as null from others (and as a
  # missing attribute entirely if the provider predates the field, e.g.
  # core_network_arn). Comparing the raw value against "" therefore reports a
  # NULL field as a populated target and waves through a subnet with no egress,
  # and startswith(null, ...) is a hard error. coalesce collapses null, "" and
  # absent to "-", which matches no real AWS id.
  byo_default_routes = {
    for key, route_table in local.byo_route_tables :
    key => [
      for route in route_table.routes : {
        gateway_id           = coalesce(try(route.gateway_id, ""), "-")
        nat_gateway_id       = coalesce(try(route.nat_gateway_id, ""), "-")
        transit_gateway_id   = coalesce(try(route.transit_gateway_id, ""), "-")
        network_interface_id = coalesce(try(route.network_interface_id, ""), "-")
        instance_id          = coalesce(try(route.instance_id, ""), "-")
        vpc_endpoint_id      = coalesce(try(route.vpc_endpoint_id, ""), "-")
        core_network_arn     = coalesce(try(route.core_network_arn, ""), "-")
        local_gateway_id     = coalesce(try(route.local_gateway_id, ""), "-")
      }
      if coalesce(try(route.cidr_block, ""), "-") == "0.0.0.0/0"
    ]
  }

  # Accepted egress targets. A Transit Gateway route MIGHT egress to the internet
  # through a central-egress VPC — not knowable from here, so accept it and let
  # the task surface a failure if egress is broken upstream. NAT instances and
  # inspection/firewall appliances (fck-nat, Palo Alto, Fortinet) appear as
  # network_interface_id / instance_id, and are standard enterprise egress.
  # Cloud WAN central egress appears as core_network_arn, Outposts as
  # local_gateway_id — both are valid default routes.
  #
  # KNOWN GAP vs the CloudFormation NetworkPrecheck: that Lambda also skipped
  # routes whose State is not "active", rejecting a blackholed default route
  # (e.g. its NAT gateway was deleted). The aws_route_table data source exposes
  # no state field, so a blackholed route still passes here.
  byo_subnet_has_egress = {
    for key, routes in local.byo_default_routes :
    key => length([
      for route in routes : route
      if route.nat_gateway_id != "-" ||
      route.transit_gateway_id != "-" ||
      route.network_interface_id != "-" ||
      route.instance_id != "-" ||
      route.vpc_endpoint_id != "-" ||
      route.core_network_arn != "-" ||
      route.local_gateway_id != "-" ||
      startswith(route.gateway_id, "vpce-")
    ]) > 0
  }

  byo_subnet_igw_only = {
    for key, routes in local.byo_default_routes :
    key => !local.byo_subnet_has_egress[key] && length([
      for route in routes : route if startswith(route.gateway_id, "igw-")
    ]) > 0
  }

  byo_bad_subnets = [
    for key, subnet_id in local.byo_subnets :
    format("%s (%s)", subnet_id, local.byo_subnet_igw_only[key]
      ? "public subnet — 0.0.0.0/0 routes through an Internet Gateway, but the scanner task runs with no public IP"
    : "no 0.0.0.0/0 route to a NAT gateway, NAT instance, appliance ENI, VPC endpoint, Transit Gateway, Cloud WAN core network or Outposts local gateway")
    if !local.byo_subnet_has_egress[key]
  ]
}

################################################################################
# Collection Token
#
# The scanner authenticates its SBOM uploads with the account's collection token.
# It goes through Secrets Manager rather than a task-definition environment
# variable, matching every other module in this repo. This keeps the token out of
# the task definition, which anything holding ecs:DescribeTaskDefinition can read
# — including the scanner task role itself, which needs that action account-wide
# for workload scanning.
#
# It does NOT keep the token out of Terraform state: aws_secretsmanager_secret_version
# stores secret_string in state in plaintext, exactly as an environment variable
# would. Treat terraform.tfstate as secret material regardless.
################################################################################

resource "aws_secretsmanager_secret" "collection_token" {
  name                    = "${local.name_prefix}${var.collection_token_secret_name}-${local.region}"
  description             = "Stream Security volume scanner collection token"
  recovery_window_in_days = var.secret_recovery_window_days

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "collection_token" {
  secret_id     = aws_secretsmanager_secret.collection_token.id
  secret_string = data.streamsec_aws_account.this.streamsec_collection_token
}

################################################################################
# ECS Cluster and Logs
################################################################################

resource "aws_ecs_cluster" "this" {
  name = local.regional_name

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${local.regional_name}"
  retention_in_days = var.log_retention_days

  tags = local.tags
}

################################################################################
# Task Definition
#
# The same task definition serves both roles: COLLECTOR_ROLE is "orchestrator"
# here and the orchestrator overrides it to "worker" when it launches children.
################################################################################

resource "aws_ecs_task_definition" "this" {
  family                   = local.name
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  ephemeral_storage {
    size_in_gib = var.ephemeral_storage_size_gib
  }

  container_definitions = jsonencode([
    {
      name      = "scanner"
      image     = var.scanner_image
      essential = true
      environment = [
        { name = "COLLECTOR_TENANT_NAME", value = local.tenant_name },
        { name = "COLLECTOR_CUSTOMER_ID", value = local.customer_id },
        { name = "COLLECTOR_REGION", value = local.region },
        { name = "COLLECTOR_STREAM_SCAN_URL", value = local.stream_scan_url },
        { name = "COLLECTOR_STREAM_SCAN_WORKSPACE", value = local.customer_id },
        { name = "COLLECTOR_SCAN_LANGUAGE_PACKAGES", value = tostring(var.scan_language_packages) },
        { name = "COLLECTOR_SCAN_DATABASES", value = tostring(var.scan_databases) },
        { name = "COLLECTOR_SCAN_AI_WORKLOADS", value = tostring(var.scan_ai_workloads) },
        { name = "COLLECTOR_SCAN_SECRETS", value = tostring(var.scan_secrets) },
        { name = "COLLECTOR_WORKLOAD_KINDS", value = var.workload_kinds },
        { name = "COLLECTOR_ROLE", value = "orchestrator" },
        { name = "COLLECTOR_SHARD_SIZE", value = tostring(var.shard_size) },
        { name = "COLLECTOR_MAX_CONCURRENT_SHARDS", value = tostring(var.max_concurrent_shards) },
        { name = "COLLECTOR_ECS_CLUSTER_ARN", value = aws_ecs_cluster.this.arn },
        { name = "COLLECTOR_ECS_TASK_DEF_ARN", value = local.task_definition_family_arn },
        { name = "COLLECTOR_ECS_SUBNET_IDS", value = join(",", local.scanner_subnet_ids) },
        { name = "COLLECTOR_ECS_SECURITY_GROUP_ID", value = aws_security_group.this.id },
      ]
      secrets = [
        {
          name      = "COLLECTOR_STREAM_SCAN_TOKEN"
          valueFrom = aws_secretsmanager_secret.collection_token.arn
        },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "scanner"
        }
      }
    }
  ])

  tags = local.tags

  depends_on = [aws_secretsmanager_secret_version.collection_token]

  lifecycle {
    precondition {
      condition     = local.customer_id != ""
      error_message = "customer_id is required — set it to the same workspace_id configured on the streamsec provider. The scanner sends it as COLLECTOR_CUSTOMER_ID / COLLECTOR_STREAM_SCAN_WORKSPACE."
    }
  }
}

################################################################################
# Daily Scan Schedule
################################################################################

resource "aws_cloudwatch_event_rule" "daily" {
  name                = "${local.regional_name}-daily"
  description         = "Trigger the Stream Security EBS scanner on a schedule"
  schedule_expression = var.schedule_expression
  state               = "ENABLED"

  tags = local.tags
}

resource "aws_cloudwatch_event_target" "daily" {
  rule      = aws_cloudwatch_event_rule.daily.name
  target_id = "ebs-scanner-daily"
  arn       = aws_ecs_cluster.this.arn
  role_arn  = aws_iam_role.events.arn

  ecs_target {
    task_definition_arn = aws_ecs_task_definition.this.arn
    launch_type         = "FARGATE"
    task_count          = 1

    network_configuration {
      subnets         = local.scanner_subnet_ids
      security_groups = [aws_security_group.this.id]
      # No public IP on the scanner task, in either network mode.
      assign_public_ip = false
    }
  }

  # The task definition references only the role ARNs, never their policies, so
  # none of the permissions the task actually needs are implicit dependencies.
  # The security group carries no ordering of its own either, so the egress path
  # is pinned here as well.
  depends_on = [
    aws_route.private_nat,
    aws_route_table_association.private,
    aws_vpc_security_group_egress_rule.all,
    aws_iam_role_policy.events,
    aws_iam_role_policy.task,
    aws_iam_role_policy.orchestrator,
    aws_iam_role_policy.execution_secrets,
    aws_iam_role_policy_attachment.execution,
  ]
}

################################################################################
# Initial Scan
#
# Kicks off one immediate scan at apply time so the first results do not wait for
# the next scheduled fire. Errors are swallowed inside the Lambda: the daily
# schedule is the fallback, and failing here would roll back an otherwise
# working install.
################################################################################

data "archive_file" "initial_scan" {
  count = var.trigger_initial_scan ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/initial_scan.py"
  output_path = "${path.module}/lambda/initial_scan.zip"
}

resource "aws_cloudwatch_log_group" "initial_scan" {
  count = var.trigger_initial_scan ? 1 : 0

  name              = "/aws/lambda/${local.regional_name}-initial-scan"
  retention_in_days = var.log_retention_days

  tags = local.tags
}

resource "aws_lambda_function" "initial_scan" {
  count = var.trigger_initial_scan ? 1 : 0

  function_name = "${local.regional_name}-initial-scan"
  role          = aws_iam_role.initial_scan[0].arn
  handler       = "initial_scan.handler"
  runtime       = "python3.13"

  # Room for the function's retry ladder (50s of backoff) plus the RunTask calls
  # themselves. The retries cover IAM eventual consistency: the policies this
  # task needs were attached seconds earlier by the same apply.
  timeout = 120

  filename         = data.archive_file.initial_scan[0].output_path
  source_code_hash = data.archive_file.initial_scan[0].output_base64sha256

  environment {
    variables = {
      CLUSTER_ARN       = aws_ecs_cluster.this.arn
      TASK_DEF_ARN      = aws_ecs_task_definition.this.arn
      SUBNET_IDS        = join(",", local.scanner_subnet_ids)
      SECURITY_GROUP_ID = aws_security_group.this.id
    }
  }

  depends_on = [aws_cloudwatch_log_group.initial_scan]

  tags = local.tags
}

resource "aws_lambda_invocation" "initial_scan" {
  count = var.trigger_initial_scan ? 1 : 0

  function_name = aws_lambda_function.initial_scan[0].function_name
  input         = jsonencode({})

  # Every policy the scan needs has to be attached before the task launches. The
  # task definition references only aws_iam_role.*.arn, so without these the
  # graph permits launching before aws_iam_role_policy.task (EC2/EBS discovery),
  # .orchestrator (RunTask/PassRole for the fan-out), .execution_secrets (the
  # collection token) or the execution-role attachment (ECR pull + awslogs)
  # exist. The task would then fail to pull, or start and get AccessDenied — and
  # initial_scan.py swallows both, with ignore_changes = all meaning it never
  # retries.
  depends_on = [
    aws_route.private_nat,
    aws_route_table_association.private,
    aws_vpc_security_group_egress_rule.all,
    aws_iam_role_policy.initial_scan,
    aws_iam_role_policy.task,
    aws_iam_role_policy.orchestrator,
    aws_iam_role_policy.execution_secrets,
    aws_iam_role_policy_attachment.execution,
    aws_cloudwatch_event_target.daily,
  ]

  # Fire once, at create. Re-running on every apply would spam scans, and the
  # CloudFormation trigger this replaces is a Create-only custom resource that
  # no-ops on update. To force another immediate scan, taint this resource or run
  # the task from the ECS console.
  lifecycle {
    ignore_changes = all
  }
}
