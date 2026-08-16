data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Plural, so it returns an empty list instead of erroring when nothing matches —
# data.aws_ecs_cluster (singular) raises on a miss and could not be used for a
# presence check. Requires ecs:ListClusters on the deploying principal.
data "aws_ecs_clusters" "existing" {}

data "streamsec_host" "this" {}

data "streamsec_aws_account" "this" {
  cloud_account_id = data.aws_caller_identity.current.account_id
}

locals {
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  name_prefix = var.resource_prefix != "" ? "${var.resource_prefix}-" : ""

  # The "-tf" marker is load-bearing, not cosmetic. The CloudFormation stack the
  # console deploys hardcodes cluster "streamsec-ebs-scanner-<region>" and task
  # definition family "streamsec-ebs-scanner", with no prefix. Matching those
  # exactly meant that applying this module into a region that already ran the
  # CloudFormation scanner did NOT fail cleanly: ecs:CreateCluster is an upsert,
  # so Terraform silently ADOPTED the live cluster into state, registered a task
  # definition into the shared family — which the CloudFormation orchestrator
  # launches children from, using its revision-less family ARN — and a later
  # terraform destroy then deleted the cluster the working stack depended on.
  # Observed for real: a live console stack in one of our own accounts produced
  # byte-identical names.
  #
  # Nothing external depends on these names. The console keys scanner regions by
  # region, and the family name is only ever resolved by the orchestrator through
  # its own COLLECTOR_ECS_TASK_DEF_ARN.
  name          = "${local.name_prefix}streamsec-ebs-scanner-tf"
  regional_name = "${local.name}-${local.region}"

  # What the console's CloudFormation stack calls its cluster in this region.
  # Used only to detect that a CloudFormation-deployed scanner is already running
  # here; never to name anything this module creates.
  cloudformation_cluster_name = "streamsec-ebs-scanner-${local.region}"

  # cluster_arns comes back NULL, not [], from a region with no ECS clusters —
  # which is the normal case for a fresh scanner install. Iterating it directly
  # fails the plan with "Iteration over null value" before anything is created.
  existing_cluster_arns = data.aws_ecs_clusters.existing.cluster_arns == null ? [] : data.aws_ecs_clusters.existing.cluster_arns

  cloudformation_coexistence_error = <<-EOT
    A CloudFormation-deployed Stream scanner is already running in ${local.region} (ECS cluster "${local.cloudformation_cluster_name}").
    Running both scans every volume twice, doubles EBS-snapshot and ingest cost, and the two compete over snapshot retention — each deletes snapshots tagged Purpose=ebs-package-collector account-wide, including the other's.
    Delete that CloudFormation stack and let it finish, then apply. To run both deliberately, set allow_cloudformation_coexistence = true.
  EOT

  cloudformation_coexistence_ok = var.allow_cloudformation_coexistence || !local.cloudformation_scanner_present

  cloudformation_scanner_present = length([
    for arn in local.existing_cluster_arns :
    arn if endswith(arn, "/${local.cloudformation_cluster_name}")
  ]) > 0

  api_url = trimsuffix(data.streamsec_host.this.url, "/")

  # A per-tenant Stream hostname is https://<tenant>.<domain>, so the first DNS
  # label is the tenant name. That does not hold behind a shared or regional
  # endpoint (app.streamsec.io), a custom CNAME, or PrivateLink endpoint DNS —
  # hence the var.tenant_name override.
  # Getting this wrong is silent: the scanner tags SBOMs with a tenant that does
  # not exist, ingest drops them, and the console still shows the region healthy.
  derived_tenant_name = split(".", replace(replace(local.api_url, "https://", ""), "http://", ""))[0]
  tenant_name         = var.tenant_name != null ? trimspace(var.tenant_name) : local.derived_tenant_name

  stream_scan_url = "${local.api_url}/openapi/vulnerabilities/stream_scan/raw"

  # Trimmed, not just null-checked. A workspace id pasted from the console with a
  # trailing space or newline is non-empty, so it passes the precondition below
  # and then ships verbatim as COLLECTOR_CUSTOMER_ID / COLLECTOR_STREAM_SCAN_WORKSPACE.
  # Ingest drops SBOMs tagged with a workspace that does not exist, and the
  # console still shows the region healthy — zero findings, no error anywhere.
  customer_id = var.customer_id == null ? "" : trimspace(var.customer_id)

  workload_kind_list = [for kind in split(",", var.workload_kinds) : trimspace(kind) if trimspace(kind) != ""]
  scan_workloads     = length(local.workload_kind_list) > 0

  # Fargate accepts only specific memory values per CPU size. A bad pair is
  # rejected by RegisterTaskDefinition mid-apply, after the VPC, NAT gateway,
  # Elastic IP, cluster, secret and four IAM roles already exist — and the NAT
  # keeps billing until someone destroys it. This is a cross-variable rule, which
  # a variable validation block cannot express on the Terraform versions this
  # module supports.
  #
  # Expressed as explicit value lists rather than min/max/step, because the
  # 256-CPU row is irregular: Fargate allows 512, 1024 and 2048 there but NOT
  # 1536. A step model accepted 1536 and failed at apply — exactly the failure
  # this check exists to prevent. Every other row is a genuine fixed increment,
  # so range() generates those.
  fargate_memory_values = {
    "256"   = [512, 1024, 2048]
    "512"   = range(1024, 4097, 1024)
    "1024"  = range(2048, 8193, 1024)
    "2048"  = range(4096, 16385, 1024)
    "4096"  = range(8192, 30721, 1024)
    "8192"  = range(16384, 61441, 4096)
    "16384" = range(32768, 122881, 8192)
  }

  task_memory_allowed   = local.fargate_memory_values[var.task_cpu]
  task_memory_number    = tonumber(var.task_memory)
  task_sizing_is_valid  = contains(local.task_memory_allowed, local.task_memory_number)
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

  # TWO SEPARATE GATES. Terraform imposes very different rules on them, and
  # collapsing them into one is the bug this shape exists to prevent.
  #
  # byo_enabled answers "did the caller ask for bring-your-own-subnet mode and
  # supply both inputs". It feeds PRECONDITIONS ONLY, where an unknown value is
  # harmless — Terraform just defers the check to apply.
  #
  # byo_validate decides whether the validation data sources are read at all, so
  # it feeds count/for_each and MUST be known at plan time in every case. It is
  # therefore built exclusively from the two bool variables. Never fold vpc_id or
  # length(subnet_ids) in here:
  #
  #   - `var.vpc_id != null` is unknown whenever vpc_id is an attribute of a VPC
  #     created in the same apply — i.e. the standard `vpc_id = module.vpc.vpc_id`
  #     wiring — which made the whole key set unknown and failed the plan with
  #     four "Invalid for_each argument" errors naming an internal local.
  #   - `length(var.subnet_ids) > 0` is unknown for a list of unknown length, and
  #     cty's && does not short-circuit on an unknown left operand, so
  #     `unknown && false` is unknown rather than false. That made
  #     validate_subnet_egress = false unable to switch anything off — the one
  #     job the flag exists for.
  byo_enabled  = !var.create_scanner_vpc && var.vpc_id != null && length(var.subnet_ids) > 0
  byo_validate = !var.create_scanner_vpc && var.validate_subnet_egress

  # Keyed by list INDEX, not by subnet id: for_each keys must be known at plan
  # time and `subnet_ids = module.vpc.private_subnets` produces ids that are not.
  # Indexes are known whenever the list LENGTH is, and unknown values are fine —
  # they only defer the preconditions to apply.
  #
  # An empty subnet_ids yields an empty map, so the "you must supply both inputs"
  # precondition in network.tf is what the operator sees, not a provider error.
  #
  # When even the length is unknown, set validate_subnet_egress = false. That
  # switches off BOTH supplied-subnet checks, the wrong-VPC one included, because
  # a for_each over an unknown-length list is rejected whichever check it feeds.
  byo_subnets = local.byo_validate ? { for index, subnet_id in var.subnet_ids : tostring(index) => subnet_id } : {}

  # Guarded on vpc_id being set: with vpc_id null every subnet would be reported
  # as "wrong VPC" on top of the real "vpc_id is required" precondition, burying
  # the message that actually tells the operator what to do.
  byo_wrong_vpc_subnets = [
    for subnet in data.aws_subnet.byo : subnet.id
    if var.vpc_id != null && subnet.vpc_id != var.vpc_id
  ]

  # Normalized to a "-" sentinel per target field. A route's unused target fields
  # come back as "" from some provider versions and as null from others (and as a
  # missing attribute entirely if the provider predates the field, e.g.
  # core_network_arn). Comparing the raw value against "" therefore reports a
  # NULL field as a populated target and waves through a subnet with no egress,
  # and startswith(null, ...) is a hard error. coalesce collapses null, "" and
  # absent to "-", which matches no real AWS id.
  byo_default_routes = {
    # The explicit-association / main-route-table fallback happens in the data
    # source itself (see network.tf).
    for key, route_table in data.aws_route_table.byo_explicit :
    key => [
      for route in route_table.routes : {
        cidr_block           = coalesce(try(route.cidr_block, ""), "-")
        prefix_list_id       = coalesce(try(route.destination_prefix_list_id, ""), "-")
        gateway_id           = coalesce(try(route.gateway_id, ""), "-")
        nat_gateway_id       = coalesce(try(route.nat_gateway_id, ""), "-")
        transit_gateway_id   = coalesce(try(route.transit_gateway_id, ""), "-")
        network_interface_id = coalesce(try(route.network_interface_id, ""), "-")
        instance_id          = coalesce(try(route.instance_id, ""), "-")
        vpc_endpoint_id      = coalesce(try(route.vpc_endpoint_id, ""), "-")
        core_network_arn     = coalesce(try(route.core_network_arn, ""), "-")
        local_gateway_id     = coalesce(try(route.local_gateway_id, ""), "-")
      }
      # ONLY a literal default route counts as a candidate.
      #
      # Managed-prefix-list routes were briefly accepted here on the reasoning
      # that a prefix list might contain 0.0.0.0/0 and we cannot read it. That
      # was badly wrong: the commonest prefix-list route in any private subnet is
      # the S3 gateway endpoint, which says nothing about internet access. It let
      # a completely isolated subnet pass, and — because the IGW-only rejection is
      # gated on this — let a genuinely public subnet pass too. A prefix list that
      # really does carry a default route is rare; validate_subnet_egress = false
      # is the escape hatch for it.
      if coalesce(try(route.cidr_block, ""), "-") == "0.0.0.0/0"
    ]
  }

  # Accepted egress targets. A Transit Gateway route MIGHT egress to the internet
  # through a central-egress VPC — not knowable from here, so accept it and let
  # the task surface a failure if egress is broken upstream. NAT instances and
  # inspection/firewall appliances (fck-nat, Palo Alto, Fortinet) appear as
  # network_interface_id / instance_id, and are standard enterprise egress.
  # Cloud WAN central egress appears as core_network_arn, Outposts as
  # local_gateway_id, and on-prem egress over Site-to-Site VPN or Direct Connect
  # appears as a virtual private gateway (gateway_id "vgw-") — all valid default
  # routes. vgw- in particular is a standard enterprise topology, and rejecting
  # it forced operators onto validate_subnet_egress = false, which switches off
  # the wrong-VPC check too.
  #
  # vpc_endpoint_id here means a Gateway Load Balancer endpoint — an inspection
  # appliance that CAN carry a default route. That is not the same thing as a
  # gateway endpoint for S3 or DynamoDB, which appears as gateway_id "vpce-" and
  # can never be internet egress; accepting the latter was the regression above.
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
      startswith(route.gateway_id, "vgw-")
    ]) > 0
  }

  byo_subnet_igw_only = {
    for key, routes in local.byo_default_routes :
    key => !local.byo_subnet_has_egress[key] && length([
      for route in routes : route
      if route.cidr_block == "0.0.0.0/0" && startswith(route.gateway_id, "igw-")
    ]) > 0
  }

  byo_bad_subnets = [
    for key, subnet_id in local.byo_subnets :
    format("%s (%s)", subnet_id, local.byo_subnet_igw_only[key]
      ? "public subnet — 0.0.0.0/0 routes through an Internet Gateway, but the scanner task runs with no public IP"
    : "no 0.0.0.0/0 route to a NAT gateway, NAT instance, appliance ENI, VPC endpoint, Transit Gateway, virtual private gateway, Cloud WAN core network or Outposts local gateway")
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

# Random suffix, matching modules/eks-audit. The CloudFormation template gives
# the secret no Name at all so CloudFormation auto-generates a unique one; a
# deterministic name re-introduces exactly what that avoids. With any non-zero
# secret_recovery_window_days, destroy-then-apply — the ordinary way to move a
# scanner or change scanner_vpc_cidr — otherwise fails for up to 30 days with
# "a secret with this name is already scheduled for deletion", after the VPC,
# NAT gateway and EIP already exist and with no force-delete escape.
resource "random_string" "secret_suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "aws_secretsmanager_secret" "collection_token" {
  name                    = "${local.name_prefix}${var.collection_token_secret_name}-${local.region}-${random_string.secret_suffix.result}"
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

  lifecycle {
    precondition {
      condition     = local.cloudformation_coexistence_ok
      error_message = local.cloudformation_coexistence_error
    }
  }
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
      condition     = local.task_sizing_is_valid
      error_message = "Fargate rejects task_cpu = ${var.task_cpu} with task_memory = ${var.task_memory}. At that CPU size the allowed memory values are ${join(", ", [for m in local.task_memory_allowed : tostring(m)])} MiB. Left unchecked this fails at RegisterTaskDefinition mid-apply, after the NAT gateway and Elastic IP are already billing."
    }

    precondition {
      condition     = local.tenant_name != ""
      error_message = "tenant_name resolved to an empty string. Leave it unset to derive the tenant from the provider host, or set it to your tenant name — an empty value tags every SBOM with a tenant that does not exist, ingest drops them, and the console still shows the region healthy."
    }

    precondition {
      condition     = local.customer_id != ""
      error_message = "customer_id is required and must not be blank — set it to the same workspace_id configured on the streamsec provider. The scanner sends it as COLLECTOR_CUSTOMER_ID / COLLECTOR_STREAM_SCAN_WORKSPACE."
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
  # Per instance: with a local module source path.module is the same directory
  # for every instantiation, so a fixed name has two instances writing and
  # hashing one file concurrently. examples/complete declares two.
  output_path = "${path.module}/lambda/initial_scan-${local.regional_name}.zip"
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
  # Matches the CloudFormation template's runtime, so the two deployments share a
  # deprecation clock and a bundled botocore rather than drifting apart.
  runtime = "python3.12"

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
  # initial_scan.py swallows both, and the invocation only re-runs when the
  # function itself is replaced — so a failure here is not retried.
  depends_on = [
    aws_route.private_nat,
    aws_route_table_association.private,
    aws_vpc_security_group_egress_rule.all,
    aws_iam_role_policy.initial_scan,
    # Without this the invocation can run before the role can write logs. The
    # function deliberately swallows every failure, so CloudWatch is the ONLY
    # place a failed first scan is visible — losing it makes the failure total.
    aws_iam_role_policy_attachment.initial_scan_basic,
    aws_iam_role_policy.task,
    aws_iam_role_policy.orchestrator,
    aws_iam_role_policy.execution_secrets,
    aws_iam_role_policy_attachment.execution,
    aws_cloudwatch_event_target.daily,
  ]

  # Fire once per Lambda, not once per apply. Re-running on every apply would
  # spam scans, and the CloudFormation trigger this replaces is a Create-only
  # custom resource that no-ops on update.
  #
  # function_name is ForceNew on aws_lambda_invocation, so renaming the
  # deployment already re-creates and re-invokes this. replace_triggered_by is
  # defence in depth, pinning that behaviour so it survives a refactor of how
  # function_name is derived. There is no ignore_changes: `input` is the constant
  # jsonencode({}) and can never change, so suppressing it protected nothing
  # while reading like the guard.
  #
  # It keys on function_name, NOT on the whole resource.
  # Referencing the resource re-fires on any in-place UPDATE to it as well as on
  # replacement, and the Lambda's environment carries the task-definition ARN —
  # so every toggle, image, sizing or shard-count change produced a new revision
  # and kicked off a full account scan on apply. Verified against real AWS:
  # flipping scan_databases planned "aws_lambda_invocation ... will be replaced
  # due to changes in replace_triggered_by". That contradicts the CloudFormation
  # trigger this replaces, which is Create-only and no-ops on stack update.
  # function_name changes only when the deployment is renamed, which is exactly
  # when the function is genuinely replaced.
  lifecycle {
    replace_triggered_by = [aws_lambda_function.initial_scan[0].function_name]
  }
}
