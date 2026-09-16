data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Plural: an empty list instead of an error on a miss; count waives the ecs:ListClusters need.
data "aws_ecs_clusters" "existing" {
  count = var.allow_cloudformation_coexistence ? 0 : 1
}

data "streamsec_host" "this" {}

data "streamsec_aws_account" "this" {
  cloud_account_id = data.aws_caller_identity.current.account_id
}

locals {
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  name_prefix = var.resource_prefix != "" ? "${var.resource_prefix}-" : ""

  # The "-tf" marker keeps these names off the ones the console CloudFormation stack hardcodes:
  # ecs:CreateCluster is an upsert, so an identical name silently adopts the live cluster.
  name          = "${local.name_prefix}streamsec-ebs-scanner-tf"
  regional_name = "${local.name}-${local.region}"

  # What the console's CloudFormation stack calls its cluster here; used only to detect it.
  cloudformation_cluster_name = "streamsec-ebs-scanner-${local.region}"

  # cluster_arns is null, not [], in an empty region; try() catches errors, not nulls.
  existing_cluster_arns = try(coalesce(data.aws_ecs_clusters.existing[0].cluster_arns, []), [])

  cloudformation_coexistence_error = <<-EOT
    Another Stream scanner is already running in ${local.region}: ${local.cloudformation_scanner_present ? "the console's CloudFormation stack (ECS cluster \"${local.cloudformation_cluster_name}\")" : "another instance of this module (${join(", ", local.other_tf_scanner_clusters)})"}. Both scan every volume and delete each other's snapshots tagged Purpose=ebs-package-collector.
    Remove that deployment, then apply. To run both deliberately, set allow_cloudformation_coexistence = true.${local.cloudformation_scanner_present ? "" : " After a resource_prefix rename the cluster above is your own previous one, which this name-based guard cannot tell apart: set the flag for that one apply, then unset it."}
  EOT

  # Maintenance apply: re-running the guard would lock an existing deployment out of destroy.
  already_installed = contains(local.existing_cluster_arns, "${local.cluster_arn_prefix}/${local.regional_name}")

  cloudformation_coexistence_ok = var.allow_cloudformation_coexistence || local.already_installed || (!local.cloudformation_scanner_present && !local.duplicate_scanner_present)

  cloudformation_scanner_present = length([
    for arn in local.existing_cluster_arns :
    arn if endswith(arn, "/${local.cloudformation_cluster_name}")
  ]) > 0

  # Another instance of this module here: snapshot cleanup is tag-scoped account-wide, so two
  # instances delete each other's snapshots. Case-insensitive; plan-time, so same-config misses.
  other_tf_scanner_clusters = [
    for arn in local.existing_cluster_arns : arn
    if length(regexall("(?i)/[a-z0-9-]*streamsec-ebs-scanner-tf-${local.region}$", arn)) > 0
    && lower(arn) != lower("${local.cluster_arn_prefix}/${local.regional_name}")
  ]

  cluster_arn_prefix        = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:cluster"
  duplicate_scanner_present = length(local.other_tf_scanner_clusters) > 0

  api_url = trimsuffix(data.streamsec_host.this.url, "/")

  # First DNS label of a per-tenant host is the tenant; untrue behind a shared endpoint.
  derived_tenant_name = split(".", replace(replace(local.api_url, "https://", ""), "http://", ""))[0]
  tenant_name         = var.tenant_name != null ? trimspace(var.tenant_name) : local.derived_tenant_name

  stream_scan_url = "${local.api_url}/openapi/vulnerabilities/stream_scan/raw"

  # Trimmed: a value pasted with trailing whitespace passes the precondition and ships verbatim.
  customer_id = var.customer_id == null ? "" : trimspace(var.customer_id)

  workload_kind_list = [for kind in split(",", var.workload_kinds) : trimspace(kind) if trimspace(kind) != ""]
  scan_workloads     = length(local.workload_kind_list) > 0

  # Fargate allows only specific memory values per CPU size; the 256 row is irregular (no 1536).
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

  # local.byo_vpc_id, not var.vpc_id — every consumer needs the trimmed value.
  scanner_vpc_id     = var.create_scanner_vpc ? aws_vpc.this[0].id : local.byo_vpc_id
  scanner_subnet_ids = var.create_scanner_vpc ? [aws_subnet.private[0].id] : local.byo_subnet_ids

  # Only when the module owns the VPC; the ebs opt-out applies to the interface endpoint only.
  create_ebs_endpoint = var.create_scanner_vpc && coalesce(var.create_ebs_vpc_endpoint, true)
  create_s3_endpoint  = var.create_scanner_vpc

  # The endpoint service is not offered in every AZ, so intersect rather than taking names[0].
  available_azs = var.create_scanner_vpc ? data.aws_availability_zones.available[0].names : []
  endpoint_azs  = local.create_ebs_endpoint ? data.aws_vpc_endpoint_service.ebs[0].availability_zones : []
  candidate_azs = local.create_ebs_endpoint ? sort(tolist(setintersection(toset(local.available_azs), toset(local.endpoint_azs)))) : local.available_azs
  scanner_az    = var.create_scanner_vpc ? try(local.candidate_azs[0], local.available_azs[0]) : null

  # aws-cn VPC endpoint service names carry a "cn." prefix.
  vpc_endpoint_service_prefix = local.partition == "aws-cn" ? "cn." : ""

  scanner_public_subnet_cidr  = cidrsubnet(var.scanner_vpc_cidr, 1, 0)
  scanner_private_subnet_cidr = cidrsubnet(var.scanner_vpc_cidr, 1, 1)

  # One private IP per task, five reserved per subnet, plus an ENI for the EBS endpoint.
  scanner_private_subnet_capacity = pow(2, 32 - tonumber(split("/", local.scanner_private_subnet_cidr)[1])) - 5 - (local.create_ebs_endpoint ? 1 : 0)
  # Orchestrator + children + the workload child launched when workload_kinds is non-empty.
  scanner_peak_task_count = var.max_concurrent_shards + 1 + (local.scan_workloads ? 1 : 0)

  # Revision-less family ARN: children run the current ACTIVE revision, and no self-reference.
  task_definition_family_arn = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:task-definition/${local.name}"

  # RunTask authorizes on the ARN passed: the orchestrator passes the family ARN, others a revision.
  run_task_resources = [
    local.task_definition_family_arn,
    "${local.task_definition_family_arn}:*",
  ]

  # Two separate gates. byo_enabled feeds preconditions only, where unknown defers the check.
  # byo_validate feeds count/for_each, so it must be known at plan time: bool variables only.
  byo_vpc_id = var.vpc_id == null ? "" : trimspace(var.vpc_id)

  # Trimmed like vpc_id. NO `if` predicate: a for expression with a condition becomes wholly
  # unknown, breaking every BYO for_each; blank elements are rejected by variable validation.
  byo_subnet_ids = [for id in var.subnet_ids : trimspace(id)]
  byo_enabled    = !var.create_scanner_vpc && local.byo_vpc_id != "" && length(local.byo_subnet_ids) > 0
  byo_validate   = !var.create_scanner_vpc && var.validate_subnet_egress

  # Keyed by list index: for_each keys must be known at plan time and subnet ids often are not.
  byo_subnets = local.byo_validate ? { for index, subnet_id in local.byo_subnet_ids : tostring(index) => subnet_id } : {}

  byo_wrong_vpc_subnets = [
    for subnet in data.aws_subnet.byo : subnet.id
    if local.byo_vpc_id != "" && subnet.vpc_id != local.byo_vpc_id
  ]

  # "-" sentinel: an unused target is "" or null by provider version, and startswith(null) errors.
  byo_default_routes = {
    for key, route_table in data.aws_route_table.byo_explicit :
    key => [
      for route in route_table.routes : {
        cidr_block           = coalesce(route.cidr_block, "-")
        prefix_list_id       = coalesce(route.destination_prefix_list_id, "-")
        gateway_id           = coalesce(route.gateway_id, "-")
        nat_gateway_id       = coalesce(route.nat_gateway_id, "-")
        transit_gateway_id   = coalesce(route.transit_gateway_id, "-")
        network_interface_id = coalesce(route.network_interface_id, "-")
        instance_id          = coalesce(route.instance_id, "-")
        vpc_endpoint_id      = coalesce(route.vpc_endpoint_id, "-")
        core_network_arn     = coalesce(route.core_network_arn, "-")
        local_gateway_id     = coalesce(route.local_gateway_id, "-")
      }
      # Only a literal default route counts: a prefix-list route is usually the S3 endpoint.
      if coalesce(route.cidr_block, "-") == "0.0.0.0/0"
    ]
  }

  # Accepted egress: NAT gateway, transit gateway, NAT instance or appliance ENI, GWLB endpoint
  # (vpc_endpoint_id — an S3 gateway endpoint is gateway_id "vpce-", never egress), Cloud
  # WAN, Outposts local gateway, vgw-. No route state is exposed, so a blackholed route passes.
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
      for route in routes : route if startswith(route.gateway_id, "igw-")
    ]) > 0
  }

  # Wrong-VPC subnets excluded: their lookup falls back to the other VPC's main route table.
  byo_bad_subnets = [
    for key, subnet_id in local.byo_subnets :
    format("%s (%s)", subnet_id, local.byo_subnet_igw_only[key]
      ? "public subnet — 0.0.0.0/0 routes through an Internet Gateway, but the scanner task runs with no public IP"
    : "no 0.0.0.0/0 route to a NAT gateway, NAT instance, appliance ENI, VPC endpoint, Transit Gateway, virtual private gateway, Cloud WAN core network or Outposts local gateway")
    if !local.byo_subnet_has_egress[key] && !contains(local.byo_wrong_vpc_subnets, subnet_id)
  ]
}

# Secrets Manager keeps the token out of the task definition; state still holds it in plaintext.
# The coexistence gate is repeated here: this secret depends on neither the VPC nor the cluster.
resource "aws_secretsmanager_secret" "collection_token" {
  # name_prefix, not name: the provider appends a unique suffix on every create,
  # which is what makes create_before_destroy below safe. A fixed name — even
  # with a random suffix held in state — is identical on both sides of a
  # replacement, so the new secret collided with the old one
  # (ResourceExistsException). This also matches the CloudFormation template,
  # whose secret has no Name and takes a generated one.
  name_prefix             = "${local.name_prefix}${var.collection_token_secret_name}-${local.region}-"
  description             = "Stream Security volume scanner collection token"
  recovery_window_in_days = var.secret_recovery_window_days

  tags = local.tags

  lifecycle {
    # Replacement is ForceNew; without this the live secret is deleted first and
    # its name stays reserved for the recovery window.
    create_before_destroy = true

    precondition {
      condition     = local.cloudformation_coexistence_ok
      error_message = local.cloudformation_coexistence_error
    }
  }
}

resource "aws_secretsmanager_secret_version" "collection_token" {
  lifecycle {
    create_before_destroy = true
  }

  secret_id     = aws_secretsmanager_secret.collection_token.id
  secret_string = data.streamsec_aws_account.this.streamsec_collection_token
}

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

# One task definition serves both roles: the orchestrator overrides COLLECTOR_ROLE to "worker".
resource "aws_ecs_task_definition" "this" {
  # skip_destroy: every attribute is ForceNew, so the only ACTIVE revision would be deregistered.
  skip_destroy = true

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
        # Normalized, not raw: the scanner's comma split would otherwise see " ecs".
        { name = "COLLECTOR_WORKLOAD_KINDS", value = join(",", local.workload_kind_list) },
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
    # public.ecr.aws has no aws-cn presence, so fail at plan rather than at task start.
    precondition {
      condition     = local.partition != "aws-cn" || !startswith(var.scanner_image, "public.ecr.aws/")
      error_message = "scanner_image points at public.ecr.aws, which the aws-cn partition cannot reach. Mirror the image into an ECR registry in your China account and set scanner_image to it."
    }

    precondition {
      condition     = local.task_sizing_is_valid
      error_message = "Fargate rejects task_cpu = ${var.task_cpu} with task_memory = ${var.task_memory}. At that CPU size the allowed memory values are ${join(", ", [for m in local.task_memory_allowed : tostring(m)])} MiB."
    }

    # Nothing else constrains the scheme: derived_tenant_name strips http:// as well.
    precondition {
      condition     = startswith(local.api_url, "https://")
      error_message = "The Stream host resolved to \"${local.api_url}\", which is not https. The scanner posts SBOMs and its collection token there; set the streamsec provider host to an https URL."
    }

    precondition {
      condition     = local.tenant_name != ""
      error_message = "tenant_name resolved to an empty string, which tags every SBOM with a tenant that does not exist. Leave it unset to derive the tenant from the provider host, or set your tenant name."
    }

    precondition {
      condition     = local.customer_id != ""
      error_message = "customer_id is required and must not be blank: set it to the same workspace_id configured on the streamsec provider."
    }
  }
}

resource "aws_cloudwatch_event_rule" "daily" {
  name                = "${local.regional_name}-daily"
  description         = "Trigger the Stream Security EBS scanner on a schedule"
  schedule_expression = var.schedule_expression
  # Variable, not a literal, so a rule disabled in the console survives the next apply.
  state = var.schedule_enabled ? "ENABLED" : "DISABLED"

  tags = local.tags
}

# Known gap: no DLQ and no retry policy, so a persistently failing RunTask is discarded.
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

  # The task definition references only role ARNs, so no policy or egress path is implicit.
  depends_on = [
    aws_route.private_nat,
    aws_route_table_association.private,
    aws_vpc_security_group_egress_rule.all,
    # Private DNS points the EBS API at the endpoint ENI; scanning before its ingress rule fails.
    aws_vpc_endpoint.ebs,
    aws_vpc_endpoint.s3,
    aws_vpc_security_group_ingress_rule.endpoints_https,
    aws_iam_role_policy.events,
    aws_iam_role_policy.task,
    aws_iam_role_policy.orchestrator,
    aws_iam_role_policy.execution_secrets,
    aws_iam_role_policy_attachment.execution,
  ]
}

# One immediate scan at apply time; errors are swallowed, the daily schedule is the fallback.
data "archive_file" "initial_scan" {
  count = var.trigger_initial_scan ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/initial_scan.py"
  # Per instance: path.module is the same directory for every instantiation of a local module.
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
  # Matches the CloudFormation template's runtime.
  runtime = "python3.12"

  # Room for the retry ladder (50s, covering IAM eventual consistency) plus the RunTask calls.
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

  # Every policy must be attached before the task launches; a failure here is never retried.
  depends_on = [
    aws_route.private_nat,
    aws_route_table_association.private,
    aws_vpc_security_group_egress_rule.all,
    aws_vpc_endpoint.ebs,
    aws_vpc_endpoint.s3,
    aws_vpc_security_group_ingress_rule.endpoints_https,
    aws_iam_role_policy.initial_scan,
    # The function swallows every failure, so CloudWatch is the only place one is visible.
    aws_iam_role_policy_attachment.initial_scan_basic,
    aws_iam_role_policy.task,
    aws_iam_role_policy.orchestrator,
    aws_iam_role_policy.execution_secrets,
    aws_iam_role_policy_attachment.execution,
    aws_cloudwatch_event_target.daily,
  ]

  # Fires once per Lambda, not per apply: re-invocation hangs off function_name (ForceNew).
}
