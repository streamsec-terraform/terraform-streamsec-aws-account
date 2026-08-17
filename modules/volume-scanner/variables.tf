################################################################################
# Scanner Image
################################################################################

variable "scanner_image" {
  description = "ECR image URI for the EBS scanner. Public ECR (same registry as the k8s agents) so the Fargate task can pull without cross-account private-ECR auth; :latest tracks the newest v* release."
  type        = string
  default     = "public.ecr.aws/stream-security/volume-scanner:latest"
}

################################################################################
# Scanner Features
#
# The scanner image defaults all of these to false; this module opts in to
# language-package scanning only, matching the CloudFormation template.
################################################################################

variable "scan_language_packages" {
  description = "Detect language-level packages on disk (Python wheels, npm package-lock, Ruby gemspec, Go modules, Rust Cargo, Java pom). The only toggle on by default — it gives the SBOM coverage most customers want from the agentless scanner."
  type        = bool
  default     = true
}

variable "scan_databases" {
  description = "Detect installed databases (MySQL, Postgres, MongoDB, Redis, etc.) via their on-disk data-directory signatures. Adds a filesystem walk to each instance scan."
  type        = bool
  default     = false
}

variable "scan_ai_workloads" {
  description = "Detect AI / ML framework installs (PyTorch, vLLM, Transformers, LangChain, OpenAI / Anthropic SDKs) and surface them as workload metadata."
  type        = bool
  default     = false
}

variable "scan_secrets" {
  description = "Detect secrets and credentials in the filesystem (55+ secret types). Significantly increases scan duration on package-heavy hosts."
  type        = bool
  default     = false
}

variable "workload_kinds" {
  description = "Serverless/container workload kinds to scan in addition to EC2 instances. \"lambda\" scans Lambda function code + layers (zip) and Lambda container images; \"ecs\" scans the images of running Fargate tasks (EC2-launch-type containers are already covered by the instance disk scan). Set to \"\" to disable workload scanning entirely."
  type        = string
  default     = "lambda,ecs"

  # Normalizes before checking, so "ecs,lambda" and "lambda, ecs" are accepted as
  # the same set rather than rejected for ordering or spacing. An exact-string
  # allow-list also made the trimspace in local.workload_kind_list unreachable.
  validation {
    condition = length(setsubtract(
      toset([for kind in split(",", var.workload_kinds) : trimspace(kind) if trimspace(kind) != ""]),
      toset(["lambda", "ecs"])
    )) == 0
    error_message = "workload_kinds must be a comma-separated subset of \"lambda\" and \"ecs\", or \"\" to disable workload scanning."
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
  description = "Instances per child task. Lower = more child tasks, more parallelism, higher RunTask volume. Higher = fewer children, longer per-task wall-clock."
  type        = number
  default     = 100

  validation {
    condition     = var.shard_size >= 1 && var.shard_size <= 5000 && floor(var.shard_size) == var.shard_size
    error_message = "shard_size must be a whole number between 1 and 5000. It is passed to the scanner as COLLECTOR_SHARD_SIZE, which parses an integer."
  }
}

variable "max_concurrent_shards" {
  description = "Maximum number of child scanner tasks the orchestrator keeps in flight at any moment. Caps EBS-Direct API rate, Fargate launch throttling, and the ingest endpoint's concurrent load."
  type        = number
  default     = 10

  validation {
    condition     = var.max_concurrent_shards >= 1 && var.max_concurrent_shards <= 100 && floor(var.max_concurrent_shards) == var.max_concurrent_shards
    error_message = "max_concurrent_shards must be a whole number between 1 and 100. A fraction is shipped verbatim as COLLECTOR_MAX_CONCURRENT_SHARDS and also makes the subnet capacity check compare against a fractional ENI count."
  }
}

################################################################################
# Task Sizing
################################################################################

variable "task_cpu" {
  description = "Fargate task CPU units. The default is a t3.xlarge profile (4 vCPU / 16 GB) sized for max_concurrent_shards = 10. Must be one of Fargate's discrete sizes: 256, 512, 1024, 2048, 4096, 8192, 16384."
  type        = string
  default     = "4096"

  # Fargate accepts only these seven values. Anything else is rejected by
  # RegisterTaskDefinition mid-apply, after the VPC, NAT gateway, cluster, secret
  # and four IAM roles already exist — so catch it at the input instead.
  validation {
    condition     = contains(["256", "512", "1024", "2048", "4096", "8192", "16384"], var.task_cpu)
    error_message = "task_cpu must be one of Fargate's supported values: 256, 512, 1024, 2048, 4096, 8192, 16384."
  }
}

variable "task_memory" {
  description = "Fargate task memory in MiB. Raise this before raising max_concurrent_shards — Syft uses 250-400 MB per concurrent host scan. Must be a value Fargate allows for the chosen task_cpu."
  type        = string
  default     = "16384"

  validation {
    # Digits only. "16384.0" satisfies tonumber() and, because cty compares
    # numbers by value, also satisfies the Fargate contains() check — then reaches
    # RegisterTaskDefinition verbatim and is rejected mid-apply.
    condition     = can(regex("^[0-9]+$", var.task_memory)) && tonumber(var.task_memory) >= 512
    error_message = "task_memory must be a whole number of MiB written without a decimal point, at least 512."
  }
}

variable "ephemeral_storage_size_gib" {
  description = "Task ephemeral storage in GiB, used for the L2 disk cache (2 GB x 10 concurrent scans by default). Minimum 21."
  type        = number
  default     = 50

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
  description = "Create a dedicated VPC, subnet pair, Internet Gateway and NAT Gateway for the scanner. Set to false to run the scanner in existing private subnets, which must have a default route to a NAT Gateway, VPC Endpoint or Transit Gateway."
  type        = bool
  default     = true
}

variable "create_ebs_vpc_endpoint" {
  description = "Create the interface VPC endpoint for the EBS Direct API so snapshot block reads bypass the NAT Gateway. Defaults to on whenever the module creates the VPC: block reads are the dominant egress cost and NAT data processing is ~4.5x the PrivateLink rate for the same bytes. Set false where the endpoint service is unavailable in your region or partition — the free S3 gateway endpoint is unaffected and is always created alongside a module-managed VPC. Leave unset in bring-your-own-subnet mode; the module does not create endpoints in a VPC it does not own, and setting this true there is rejected rather than silently ignored."
  type        = bool

  # Tri-state on purpose. Unset means "on when the module owns the VPC, off
  # otherwise", so bring-your-own-subnet callers need no ceremony; an EXPLICIT
  # true in that mode is a real misunderstanding and gets a precondition rather
  # than silence.
  default = null
}

variable "scanner_vpc_cidr" {
  description = "CIDR block for the scanner VPC when create_scanner_vpc is true. Split into two equal halves: the lower one is the public subnet (NAT Gateway only, no Fargate task ever runs there) and the upper one is the private subnet where the scanner runs."
  type        = string
  default     = "10.255.0.0/24"

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
    condition = can(cidrsubnet(var.scanner_vpc_cidr, 1, 1)) && can(
      tonumber(split("/", var.scanner_vpc_cidr)[1])
      ) && tonumber(split("/", var.scanner_vpc_cidr)[1]) <= 27 && tonumber(
      split("/", var.scanner_vpc_cidr)[1]
    ) >= 16
    error_message = "scanner_vpc_cidr must be a valid IPv4 CIDR block between /16 and /27. AWS rejects VPCs larger than /16, and the block is split into two subnets, which AWS rejects below /28."
  }
}

variable "validate_subnet_egress" {
  description = "Validate at plan time that every supplied subnet has a default route to a NAT gateway, NAT instance, appliance ENI, VPC endpoint or Transit Gateway. Set to false when subnet_ids are created in the same apply and their count is not known until then — Terraform cannot key the validation data sources off values it does not have yet."
  type        = bool
  default     = true
}

variable "vpc_id" {
  description = "VPC for the scanner Fargate tasks. Required when create_scanner_vpc is false. The scanner uses this VPC only for egress — it scans the whole account/region through the EBS Direct API regardless of which VPC the scanned workloads are in."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "COST NOTE: the scanner reads snapshot blocks over the EBS Direct API, which is the dominant source of egress traffic, and if these subnets reach it through a NAT Gateway you pay NAT data processing on every byte. Adding an interface VPC endpoint for com.amazonaws.<region>.ebs to your VPC (plus a gateway endpoint for S3) typically cuts the scanner's total AWS cost by roughly half. The module does not create them in this mode because it does not own the VPC; in the default networking mode it creates both for you. Private subnets for the scanner Fargate tasks. Required when create_scanner_vpc is false. Each subnet MUST have a default route to a NAT Gateway, VPC Endpoint or Transit Gateway — the tasks run with no public IP, so a public subnet with only an Internet Gateway route is a black hole. Validated at plan time."
  type        = list(string)
  default     = []
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
  description = "EventBridge schedule for the daily scan. Must be a cron expression: a rate(...) rule with State ENABLED fires once at rule creation as well as on the interval, which would launch a second orchestrator concurrently with the initial-scan trigger."
  type        = string
  default     = "cron(0 3 * * ? *)"

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

variable "trigger_initial_scan" {
  description = "Run one immediate scan at apply time so the first results do not wait for the next scheduled fire. Failures are swallowed — the daily schedule is the fallback and a failed first scan never fails the apply."
  type        = bool
  default     = true
}

variable "collection_token_secret_name" {
  description = "Base name for the Secrets Manager secret holding the Stream collection token the scanner authenticates its SBOM uploads with. The region is appended, so one secret exists per deployed region."
  type        = string
  default     = "streamsec-scanner-collection-token"
  # The only name-forming input without a character check. Secrets Manager accepts
  # [A-Za-z0-9/_+=.@-]; anything else fails CreateSecret mid-apply, after the VPC,
  # NAT gateway and Elastic IP already exist.
  validation {
    condition     = can(regex("^[A-Za-z0-9/_+=.@-]+$", var.collection_token_secret_name))
    error_message = "collection_token_secret_name may contain only letters, digits and the characters / _ + = . @ - which is what Secrets Manager accepts."
  }
}

variable "secret_recovery_window_days" {
  description = "Days Secrets Manager waits before deleting the collection-token secret. 0 deletes immediately. Any other value must be 7-30, the range Secrets Manager accepts."
  type        = number
  default     = 0

  # Secrets Manager accepts 0 (force delete) or 7-30. Everything in between is
  # rejected by the DeleteSecret call at destroy time — the worst moment to find
  # out, because the rest of the stack is already gone.
  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0 (delete immediately) or between 7 and 30."
  }
}

variable "allow_cloudformation_coexistence" {
  description = "Permit applying this module into a region where the console's CloudFormation scanner stack is still deployed. Off by default: the two scan every volume twice and compete over snapshot retention, since each deletes snapshots tagged Purpose=ebs-package-collector account-wide — including the other's. Turn on only for a deliberate side-by-side migration."
  type        = bool
  default     = false
}

variable "scan_encrypted_volumes" {
  description = "Grant the scanner task the KMS permissions it needs to read snapshots of ENCRYPTED EBS volumes. Leaving this off means encrypted instances are silently skipped — the scanner snapshots them, fails every block read, and reports no findings for them with no error surfaced anywhere. Turn it off only if every volume in the region is unencrypted, or if you deliberately want encrypted volumes excluded."
  type        = bool
  default     = true
}

variable "kms_key_arns" {
  description = "KMS keys the scanner may use to read encrypted volumes. Defaults to [\"*\"] because customer CMK ARNs are not knowable at plan time; narrow it to the specific EBS keys in the region if you can enumerate them. Ignored when scan_encrypted_volumes is false."
  type        = list(string)
  default     = ["*"]

  validation {
    condition     = length(var.kms_key_arns) > 0
    error_message = "kms_key_arns must not be empty — use scan_encrypted_volumes = false to drop the KMS grants entirely."
  }
}

variable "log_retention_days" {
  description = "Retention in days for the scanner's CloudWatch log groups. Must be one of CloudWatch's fixed retention values, or 0 to retain forever."
  type        = number
  default     = 30
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
  description = "Stream Security customer/workspace id — the same value configured as workspace_id on the streamsec provider. Sent to the scanner as COLLECTOR_CUSTOMER_ID and COLLECTOR_STREAM_SCAN_WORKSPACE, and used for the streamsec:customer tag. This becomes optional once terraform-provider-streamsec exposes customer_id as a data source attribute."
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
  description = "Stream Security tenant name, sent to the scanner as COLLECTOR_TENANT_NAME. Defaults to the first DNS label of the provider's host, which is correct for a per-tenant hostname (https://<tenant>.streamsec.io) but wrong behind a shared/regional endpoint, a custom CNAME or a PrivateLink endpoint DNS name — set it explicitly in those cases."
  type        = string
  default     = null
  validation {
    condition     = var.tenant_name == null ? true : trimspace(var.tenant_name) != ""
    error_message = "tenant_name must not be blank. Leave it unset to derive the tenant from the provider host — a blank value tags every SBOM with a tenant that does not exist, ingest drops them, and the console still shows the region healthy."
  }
}

variable "resource_prefix" {
  description = "Optional prefix prepended to all created resource names. Empty keeps names identical to the CloudFormation deployment. Capped at 9 characters because the generated IAM role names already consume all but 10 of IAM's 64-character limit."
  type        = string
  default     = ""

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
}
