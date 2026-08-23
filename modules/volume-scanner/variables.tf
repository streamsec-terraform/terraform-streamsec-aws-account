################################################################################
# What the Stream console asks you for — the CloudFormation template's
# Parameters, one for one. create_scanner_vpc is the only addition: the console
# picks it at render time, so it has to surface as an input here. vpc_id and
# subnet_ids are the console's VpcId / SubnetIds.
################################################################################

variable "scanner_image" {
  description = "ECR image URI for the scanner. Not reachable from aws-cn — mirror it and override there."
  type        = string
  default     = "public.ecr.aws/stream-security/volume-scanner:latest"
  nullable    = false
}

# The image defaults every scan toggle to false; this module opts in to language packages only.
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

  # Normalized before checking, so "ecs, lambda" is accepted. "" disables workload
  # scanning deliberately; "  " or "," would disable it silently, dropping the IAM grants.
  validation {
    condition = length(setsubtract(
      toset([for kind in split(",", var.workload_kinds) : trimspace(kind) if trimspace(kind) != ""]),
      toset(["lambda", "ecs"])
      )) == 0 && (
      var.workload_kinds == "" ||
      length([for kind in split(",", var.workload_kinds) : kind if trimspace(kind) != ""]) > 0
    )
    error_message = "workload_kinds must be a comma-separated subset of \"lambda\" and \"ecs\", or exactly \"\" to disable workload scanning."
  }
}

# The orchestrator launches one child Fargate task per shard; the defaults scan 1000 per wave.
variable "shard_size" {
  description = "Instances per child task. Lower means more parallelism; higher means fewer, longer-running children."
  type        = number
  default     = 100
  nullable    = false

  validation {
    condition     = var.shard_size >= 1 && var.shard_size <= 5000 && floor(var.shard_size) == var.shard_size
    error_message = "shard_size must be a whole number between 1 and 5000."
  }
}

variable "max_concurrent_shards" {
  description = "Maximum child scanner tasks in flight at once. Each consumes one subnet IP address."
  type        = number
  default     = 10
  nullable    = false

  validation {
    condition     = var.max_concurrent_shards >= 1 && var.max_concurrent_shards <= 100 && floor(var.max_concurrent_shards) == var.max_concurrent_shards
    error_message = "max_concurrent_shards must be a whole number between 1 and 100."
  }
}

# Default: a dedicated VPC with a public/private subnet pair, an Internet Gateway
# and a NAT Gateway with a stable Elastic IP. Tasks run private with no public IP.
variable "create_scanner_vpc" {
  description = "Create a dedicated VPC, subnets, Internet Gateway and NAT Gateway for the scanner. False to use your own private subnets."
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
  # Blanks cannot be filtered in a local: a for-expression with an if predicate goes
  # wholly unknown, breaking the index-keyed validation. Reject them at the input.
  validation {
    condition     = alltrue([for id in var.subnet_ids : trimspace(id) != ""])
    error_message = "subnet_ids must not contain blank entries: a blank id reaches RunTask verbatim and every task fails to launch."
  }
}

################################################################################
# Advanced — the console exposes none of these; the CloudFormation template
# hardcodes them, and every default below reproduces the console deployment
# exactly. They exist so a customer with a reason to differ need not fork.
################################################################################

variable "task_cpu" {
  description = "Fargate task CPU units. One of 256, 512, 1024, 2048, 4096, 8192, 16384."
  type        = string
  default     = "4096"
  nullable    = false

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
    # Digits only: "16384.0" passes tonumber() and, since cty compares numbers by
    # value, contains() too — then fails RegisterTaskDefinition mid-apply.
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

  validation {
    condition     = floor(var.ephemeral_storage_size_gib) == var.ephemeral_storage_size_gib
    error_message = "ephemeral_storage_size_gib must be a whole number of GiB."
  }
}

variable "scanner_vpc_cidr" {
  description = "CIDR for the scanner VPC. Split in half: public for the NAT Gateway, private for the tasks."
  type        = string
  default     = "10.255.0.0/24"
  nullable    = false

  # Both bounds fail mid-apply if unchecked: AWS rejects a VPC CIDR larger than /16,
  # and the block is halved, so anything below /28 is an invalid subnet.
  validation {
    # Every operand is total (try) — Terraform only short-circuits && / || from v1.12.
    condition     = can(cidrsubnet(var.scanner_vpc_cidr, 1, 1)) && try(tonumber(split("/", var.scanner_vpc_cidr)[1]), 0) <= 27 && try(tonumber(split("/", var.scanner_vpc_cidr)[1]), 0) >= 16
    error_message = "scanner_vpc_cidr must be a valid IPv4 CIDR block between /16 and /27: AWS rejects anything larger, and the block is split into two subnets."
  }
}

variable "create_ebs_vpc_endpoint" {
  description = "Create the EBS Direct API interface endpoint so snapshot block reads bypass the NAT Gateway, which is the bulk of the scanner's egress. On by default when the module creates the VPC. Leave unset otherwise."
  type        = bool

  # Tri-state: null means on when the module owns the VPC, off otherwise; an explicit
  # true with bring-your-own subnets gets a precondition.
  default = null
}

variable "validate_subnet_egress" {
  description = "Check supplied subnets for egress, VPC membership, zone and capacity. Set false when the subnet list length is unknown at plan; that disables all of those checks."
  type        = bool
  default     = true
  nullable    = false
}

variable "schedule_expression" {
  description = "EventBridge schedule for the daily scan. Must be a six-field cron expression; rate(...) is rejected."
  type        = string
  default     = "cron(0 3 * * ? *)"
  nullable    = false

  # EventBridge cron takes SIX fields, not Unix cron's five, and must be closed.
  validation {
    condition = startswith(var.schedule_expression, "cron(") && endswith(var.schedule_expression, ")") && length(
      compact(split(" ", trimspace(replace(replace(var.schedule_expression, "cron(", ""), ")", ""))))
    ) == 6
    error_message = "schedule_expression must be a closed six-field cron(...) expression: a rate(...) rule fires once at creation as well as on its interval, duplicating the first scan."
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

variable "log_retention_days" {
  description = "Retention in days for the scanner log groups. Must be a CloudWatch retention value, or 0 to keep forever."
  type        = number
  default     = 30
  nullable    = false
  validation {
    condition = contains(
      [0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.log_retention_days
    )
    error_message = "log_retention_days must be one of CloudWatch's retention values: 0 (forever), 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288 or 3653."
  }

  validation {
    condition     = floor(var.log_retention_days) == var.log_retention_days
    error_message = "log_retention_days must be a whole number of days."
  }
}

variable "collection_token_secret_name" {
  description = "Base name for the Secrets Manager secret holding the collection token. Region and a random suffix are appended."
  type        = string
  default     = "streamsec-scanner-collection-token"
  nullable    = false
  # Secrets Manager accepts [A-Za-z0-9/_+=.@-]; anything else fails CreateSecret mid-apply.
  validation {
    condition     = can(regex("^[A-Za-z0-9/_+=.@-]+$", var.collection_token_secret_name))
    error_message = "collection_token_secret_name may contain only letters, digits and the characters / _ + = . @ - which is what Secrets Manager accepts."
  }
}

variable "secret_recovery_window_days" {
  description = "Days Secrets Manager waits before deleting the secret. 0, or 7-30."
  type        = number
  # 30 matches the console stack, which omits RecoveryWindowInDays.
  default  = 30
  nullable = false

  # Secrets Manager accepts 0 (force delete) or 7-30; values in between are rejected
  # by DeleteSecret at destroy time, once the rest of the stack is already gone.
  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0 (delete immediately) or between 7 and 30."
  }

  validation {
    condition     = floor(var.secret_recovery_window_days) == var.secret_recovery_window_days
    error_message = "secret_recovery_window_days must be a whole number of days."
  }
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

variable "allow_cloudformation_coexistence" {
  description = "Allow deploying alongside another scanner in the same region. Off by default: two scanners scan every volume twice and delete each other's snapshots."
  type        = bool
  default     = false
  nullable    = false
}

variable "customer_id" {
  description = "Stream Security workspace id — the same value as the provider's workspace_id. A wrong value is silent: SBOMs are dropped by ingest and the region still looks healthy."
  type        = string
  default     = null
  # Checked here so a blank value names this input rather than failing deep in the graph.
  validation {
    condition     = var.customer_id == null ? true : trimspace(var.customer_id) != ""
    error_message = "customer_id must not be blank: a blank value tags every SBOM with a workspace that does not exist and ingest drops them. Set it to the streamsec provider's workspace_id."
  }
}

variable "tenant_name" {
  description = "Stream Security tenant name. Defaults to the first DNS label of the provider host; set it explicitly behind a shared endpoint, custom CNAME or PrivateLink DNS."
  type        = string
  default     = null
  validation {
    condition     = var.tenant_name == null ? true : trimspace(var.tenant_name) != ""
    error_message = "tenant_name must not be blank. Leave it unset to derive the tenant from the provider host."
  }
}

variable "resource_prefix" {
  description = "Prefix for all created resource names. Max 9 characters, letters/digits/hyphens — IAM role names consume the rest of the 64-char limit."
  type        = string
  default     = ""
  nullable    = false

  # The longest generated name, <prefix>-streamsec-ebs-scanner-tf-<region>-execution-role,
  # spends 54 of IAM's 64 characters (assuming the longest region, since validation cannot
  # read data sources), leaving 9 for the prefix. ECS and IAM names also reject other chars.
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
