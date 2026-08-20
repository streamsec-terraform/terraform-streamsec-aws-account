################################################################################
# Scanner Image
################################################################################

variable "scanner_image" {
  description = "ECR image URI for the scanner. Not reachable from aws-cn — mirror it and override there."
  type        = string
  default     = "public.ecr.aws/stream-security/volume-scanner:latest"
  nullable    = false
}

################################################################################
# Scanner Features
#
# The scanner image defaults all of these to false; this module opts in to
# language-package scanning only, matching the CloudFormation template.
################################################################################

variable "scan_language_packages" {
  description = "Detect language-level packages on disk (Python, Node, Ruby, Go, Rust, Java). The only toggle on by default."
  type        = bool
  default     = true
  nullable    = false
}

variable "scan_databases" {
  description = "Detect installed databases from their on-disk signatures. Adds a filesystem walk per instance."
  type        = bool
  default     = false
  nullable    = false
}

variable "scan_ai_workloads" {
  description = "Detect AI/ML framework installs and surface them as workload metadata."
  type        = bool
  default     = false
  nullable    = false
}

variable "scan_secrets" {
  description = "Detect secrets and credentials on disk. Significantly increases scan duration."
  type        = bool
  default     = false
  nullable    = false
}

variable "workload_kinds" {
  description = "Workloads to scan besides EC2: \"lambda\", \"ecs\", \"lambda,ecs\", or \"\" to disable. Also gates the matching IAM grants."
  type        = string
  default     = "lambda,ecs"
  nullable    = false

  # Normalizes before checking, so "ecs,lambda" and "lambda, ecs" are accepted as
  # the same set rather than rejected for ordering or spacing. An exact-string
  # allow-list also made the trimspace in local.workload_kind_list unreachable.
  validation {
    # Two clauses: every named kind must be known, AND a non-empty input must
    # yield at least one kind. "" disables workload scanning deliberately; "  "
    # or "," would disable it SILENTLY, dropping the IAM grants with it.
    condition = length(setsubtract(
      toset([for kind in split(",", var.workload_kinds) : trimspace(kind) if trimspace(kind) != ""]),
      toset(["lambda", "ecs"])
      )) == 0 && (
      var.workload_kinds == "" ||
      length([for kind in split(",", var.workload_kinds) : kind if trimspace(kind) != ""]) > 0
    )
    error_message = "workload_kinds must be a comma-separated subset of \"lambda\" and \"ecs\", or exactly \"\" to disable workload scanning. A whitespace-only or comma-only value would disable it silently and drop the workload IAM grants with it."
  }
}

################################################################################
# Scanner Scaling
#
# The orchestrator task discovers instances and launches one child Fargate task
# per shard. The defaults (100 instances per shard, 10 concurrent) scan up to
# 1000 instances per wave; raise max_concurrent_shards for larger fleets.
################################################################################

variable "shard_size" {
  description = "Instances per child task. Lower means more parallelism; higher means fewer, longer-running children."
  type        = number
  default     = 100
  nullable    = false

  validation {
    condition     = var.shard_size >= 1 && var.shard_size <= 5000 && floor(var.shard_size) == var.shard_size
    error_message = "shard_size must be a whole number between 1 and 5000. It is passed to the scanner as COLLECTOR_SHARD_SIZE, which parses an integer."
  }
}

variable "max_concurrent_shards" {
  description = "Maximum child scanner tasks in flight at once. Each consumes one subnet IP address."
  type        = number
  default     = 10
  nullable    = false

  validation {
    condition     = var.max_concurrent_shards >= 1 && var.max_concurrent_shards <= 100 && floor(var.max_concurrent_shards) == var.max_concurrent_shards
    error_message = "max_concurrent_shards must be a whole number between 1 and 100. A fraction is shipped verbatim as COLLECTOR_MAX_CONCURRENT_SHARDS and also makes the subnet capacity check compare against a fractional ENI count."
  }
}

################################################################################
# Task Sizing
################################################################################

variable "task_cpu" {
  description = "Fargate task CPU units. One of 256, 512, 1024, 2048, 4096, 8192, 16384."
  type        = string
  default     = "4096"
  nullable    = false

  # Fargate accepts only these seven values. Anything else is rejected by
  # RegisterTaskDefinition mid-apply, after the VPC, NAT gateway, cluster, secret
  # and four IAM roles already exist — so catch it at the input instead.
  validation {
    condition     = contains(["256", "512", "1024", "2048", "4096", "8192", "16384"], var.task_cpu)
    error_message = "task_cpu must be one of Fargate's supported values: 256, 512, 1024, 2048, 4096, 8192, 16384."
  }
}

variable "task_memory" {
  description = "Fargate task memory in MiB. Raise before raising max_concurrent_shards. Must be valid for the chosen task_cpu."
  type        = string
  default     = "16384"
  nullable    = false

  validation {
    # Digits only. "16384.0" satisfies tonumber() and, because cty compares
    # numbers by value, also satisfies the Fargate contains() check — then reaches
    # RegisterTaskDefinition verbatim and is rejected mid-apply.
    condition     = can(regex("^[0-9]+$", var.task_memory)) && try(tonumber(var.task_memory), 0) >= 512
    error_message = "task_memory must be a whole number of MiB written without a decimal point, at least 512."
  }
}

variable "ephemeral_storage_size_gib" {
  description = "Task ephemeral storage in GiB for the scanner's disk cache. Minimum 21."
  type        = number
  default     = 50
  nullable    = false

  validation {
    condition     = var.ephemeral_storage_size_gib >= 21 && var.ephemeral_storage_size_gib <= 200
    error_message = "ephemeral_storage_size_gib must be between 21 and 200 (Fargate limits)."
  }
}

################################################################################
# Networking
#
# Default (create_scanner_vpc = true) provisions a dedicated VPC with a public +
# private subnet pair, an Internet Gateway on the public subnet, and a NAT
# Gateway with a stable Elastic IP. The scanner Fargate task runs in the private
# subnet with no public IP — outbound reaches AWS APIs, public ECR, the Anchore
# Grype DB and Stream ingest through the NAT. This satisfies enterprise policies
# that flag any public IP on compute (SOC 2, CIS AWS Foundations, PCI-DSS) and
# gives a stable egress IP to allowlist upstream.
################################################################################

variable "create_scanner_vpc" {
  description = "Create a dedicated VPC, subnets, Internet Gateway and NAT Gateway for the scanner. False to use your own private subnets."
  type        = bool
  default     = true
  nullable    = false
}

variable "create_ebs_vpc_endpoint" {
  description = "Create the EBS Direct API interface endpoint so snapshot block reads bypass the NAT Gateway, which is the bulk of the scanner's egress. On by default when the module creates the VPC. Leave unset otherwise."
  type        = bool

  # Tri-state on purpose. Unset means "on when the module owns the VPC, off
  # otherwise", so bring-your-own-subnet callers need no ceremony; an EXPLICIT
  # true in that mode is a real misunderstanding and gets a precondition rather
  # than silence.
  default = null
}

variable "scanner_vpc_cidr" {
  description = "CIDR for the scanner VPC. Split in half: public for the NAT Gateway, private for the tasks."
  type        = string
  default     = "10.255.0.0/24"
  nullable    = false

  # BOTH bounds matter, and both fail mid-apply if unchecked.
  #
  # Lower: cidrsubnet() alone succeeds all the way down to /31, but AWS rejects
  # any subnet smaller than /28 and this CIDR is halved before it becomes one, so
  # a /28 VPC plans clean and then fails with InvalidSubnet.Range.
  #
  # Upper: AWS rejects a VPC CIDR larger than /16, so carving the scanner out of
  # a supernet ("10.0.0.0/8") plans clean and fails with InvalidVpc.Range — after
  # the availability-zone lookup has run and the rest of the graph is in flight.
  validation {
    # Every operand is TOTAL — try() gives each a value rather than raising — so
    # this does not depend on || / && short-circuiting, which Terraform only does
    # from v1.12. Below that both sides are always evaluated, and an unguarded
    # split("/", "10.255.0.0")[1] raised "Invalid index" instead of emitting the
    # error_message below.
    condition     = can(cidrsubnet(var.scanner_vpc_cidr, 1, 1)) && try(tonumber(split("/", var.scanner_vpc_cidr)[1]), 0) <= 27 && try(tonumber(split("/", var.scanner_vpc_cidr)[1]), 0) >= 16
    error_message = "scanner_vpc_cidr must be a valid IPv4 CIDR block between /16 and /27. AWS rejects VPCs larger than /16, and the block is split into two subnets, which AWS rejects below /28."
  }
}

variable "validate_subnet_egress" {
  description = "Check supplied subnets for egress, VPC membership, zone and capacity. Set false when the subnet list length is unknown at plan; that disables all of those checks."
  type        = bool
  default     = true
  nullable    = false
}

variable "vpc_id" {
  description = "VPC for the scanner tasks, required when create_scanner_vpc is false. Used for egress only; the scan covers the whole region regardless."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "Existing private subnets for the scanner tasks, required when create_scanner_vpc is false. Add an EBS Direct API interface endpoint to your VPC to keep block reads off the NAT Gateway."
  type        = list(string)
  default     = []
  nullable    = false
  # A blank element cannot be filtered out in a local: a for-expression with a
  # condition becomes wholly unknown when the values are unknown, which breaks the
  # index-keyed validation design. Rejecting it at the input works instead, and
  # Terraform skips variable validation for unknown values, so the standard
  # `subnet_ids = module.vpc.private_subnets` wiring is unaffected.
  validation {
    condition     = alltrue([for id in var.subnet_ids : trimspace(id) != ""])
    error_message = "subnet_ids must not contain blank entries. An empty or whitespace-only id reaches RunTask verbatim and every task fails to launch after an otherwise clean apply."
  }
}

################################################################################
# Schedule
################################################################################

variable "schedule_expression" {
  description = "EventBridge schedule for the daily scan. Must be a six-field cron expression; rate(...) is rejected."
  type        = string
  default     = "cron(0 3 * * ? *)"
  nullable    = false

  validation {
    # EventBridge cron takes SIX fields, not the five of Unix cron, and the
    # prefix check alone let "cron(0 3 * * ?)" and an unclosed "cron(0 3 * * ? *"
    # through to fail at CreateRule after most of the stack exists.
    condition = startswith(var.schedule_expression, "cron(") && endswith(var.schedule_expression, ")") && length(
      compact(split(" ", trimspace(replace(replace(var.schedule_expression, "cron(", ""), ")", ""))))
    ) == 6
    error_message = "schedule_expression must be a closed six-field cron(...) expression. A rate(...) rule fires once at creation as well as on its interval, racing a second full-account orchestrator against the initial scan and doubling snapshot and Fargate spend."
  }
}

variable "schedule_enabled" {
  description = "Enable the daily scan schedule. Set false to pause scanning — before a destroy, during an incident, or for a maintenance window."
  type        = bool
  nullable    = false
  default     = true
}

variable "trigger_initial_scan" {
  description = "Run one immediate scan at apply time. Failures are swallowed; the daily schedule is the fallback."
  type        = bool
  default     = true
  nullable    = false
}

variable "collection_token_secret_name" {
  description = "Base name for the Secrets Manager secret holding the collection token. Region and a random suffix are appended."
  type        = string
  default     = "streamsec-scanner-collection-token"
  nullable    = false
  # The only name-forming input without a character check. Secrets Manager accepts
  # [A-Za-z0-9/_+=.@-]; anything else fails CreateSecret mid-apply, after the VPC,
  # NAT gateway and Elastic IP already exist.
  validation {
    condition     = can(regex("^[A-Za-z0-9/_+=.@-]+$", var.collection_token_secret_name))
    error_message = "collection_token_secret_name may contain only letters, digits and the characters / _ + = . @ - which is what Secrets Manager accepts."
  }
}

variable "secret_recovery_window_days" {
  description = "Days Secrets Manager waits before deleting the secret. 0, or 7-30."
  type        = number
  default     = 0
  nullable    = false

  # Secrets Manager accepts 0 (force delete) or 7-30. Everything in between is
  # rejected by the DeleteSecret call at destroy time — the worst moment to find
  # out, because the rest of the stack is already gone.
  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0 (delete immediately) or between 7 and 30."
  }
}

variable "allow_cloudformation_coexistence" {
  description = "Allow deploying alongside another scanner in the same region. Off by default: two scanners scan every volume twice and delete each other's snapshots."
  type        = bool
  default     = false
  nullable    = false
}

variable "scan_encrypted_volumes" {
  description = "Grant the KMS permissions needed to read snapshots of encrypted volumes. Off means those instances report no findings, with no error anywhere."
  type        = bool
  default     = true
  nullable    = false
}

variable "kms_key_arns" {
  description = "KMS keys the scanner may use for encrypted volumes. Narrow from [\"*\"] if you can enumerate your EBS keys."
  type        = list(string)
  default     = ["*"]
  nullable    = false

  validation {
    condition     = length(var.kms_key_arns) > 0
    error_message = "kms_key_arns must not be empty — use scan_encrypted_volumes = false to drop the KMS grants entirely."
  }
}

variable "log_retention_days" {
  description = "Retention in days for the scanner log groups. Must be a CloudWatch retention value, or 0 to keep forever."
  type        = number
  default     = 30
  nullable    = false
  # The provider schema already rejects a bad value at plan time — verified, it is
  # not an apply-time failure — so this is for the message and for consistency
  # with every other numeric input here, not to close a correctness gap.
  validation {
    condition = contains(
      [0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.log_retention_days
    )
    error_message = "log_retention_days must be one of CloudWatch's retention values: 0 (forever), 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288 or 3653."
  }
}

################################################################################
# General
################################################################################

variable "customer_id" {
  description = "Stream Security workspace id — the same value as the provider's workspace_id. A wrong value is silent: SBOMs are dropped by ingest and the region still looks healthy."
  type        = string
  default     = null
  # Checked here rather than only in a precondition deep in the graph, so a
  # blank value names the offending input instead of reporting a failure against
  # aws_ecs_task_definition after both streamsec data sources have been read.
  validation {
    condition     = var.customer_id == null ? true : trimspace(var.customer_id) != ""
    error_message = "customer_id must not be blank. It is sent as COLLECTOR_CUSTOMER_ID / COLLECTOR_STREAM_SCAN_WORKSPACE, and a blank value tags every SBOM with a workspace that does not exist — ingest drops them and the console still shows the region healthy."
  }
}

variable "tenant_name" {
  description = "Stream Security tenant name. Defaults to the first DNS label of the provider host; set it explicitly behind a shared endpoint, custom CNAME or PrivateLink DNS."
  type        = string
  default     = null
  validation {
    condition     = var.tenant_name == null ? true : trimspace(var.tenant_name) != ""
    error_message = "tenant_name must not be blank. Leave it unset to derive the tenant from the provider host — a blank value tags every SBOM with a tenant that does not exist, ingest drops them, and the console still shows the region healthy."
  }
}

variable "resource_prefix" {
  description = "Prefix for all created resource names. Max 9 characters, letters/digits/hyphens — IAM role names consume the rest of the 64-char limit."
  type        = string
  default     = ""
  nullable    = false

  # The longest generated name is the execution role:
  #   <prefix>-streamsec-ebs-scanner-tf-<region>-execution-role
  #     "streamsec-ebs-scanner-tf"  24
  #     "-" + region                15  (longest region: ap-southeast-7 / cn-northwest-1, 14)
  #     "-execution-role"           15
  #                                ---
  #                                 54, leaving 10 for "<prefix>-" → 9 for the prefix.
  #
  # The "-tf" marker added 3 characters; shortening the initial-scan role suffix
  # to "-init-role" gave them back, so the cap is unchanged.
  #
  # Validation blocks cannot read data sources, so the region cannot be measured
  # here and the cap has to assume the longest one. Cap it at the input the
  # operator set rather than letting four IAM errors land mid-plan.
  # The other half of the contract: ECS cluster names allow only [a-zA-Z0-9_-]
  # and IAM role names only [\w+=,.@-], so a space or colon fails CreateCluster
  # mid-apply after the VPC, NAT gateway and Elastic IP exist.
  validation {
    condition     = can(regex("^[a-zA-Z0-9-]*$", var.resource_prefix))
    error_message = "resource_prefix may contain only letters, digits and hyphens — it becomes part of ECS cluster and IAM role names, which reject anything else."
  }

  validation {
    condition     = length(var.resource_prefix) <= 9
    error_message = "resource_prefix must be 9 characters or fewer — the longest generated IAM role name (<prefix>-streamsec-ebs-scanner-tf-<region>-execution-role) must fit IAM's 64-character limit."
  }
}

variable "tags" {
  description = "A map of global tags to add to all created resources"
  type        = map(string)
  default     = {}
  nullable    = false
}
