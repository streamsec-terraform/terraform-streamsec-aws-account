# terraform-streamsec-aws-account/volume-scanner

Terraform module for the Stream Agentless Scanner (EBS) — agentless vulnerability scanning of your EC2 instances, Lambda functions and Fargate task images. A Fargate task runs on a schedule, snapshots EBS volumes, extracts SBOMs, and ships them to Stream Security for CVE matching. No agents on your instances, no credentials granted to Stream.

This is the Terraform equivalent of the CloudFormation stack the console deploys from **Integrations → Vulnerability Scanners → Stream Agentless Scanner**. Deploy a region with one or the other, not both.

> **Migrating from the CloudFormation stack: delete it first.** The module refuses to apply while the console's scanner is deployed in the region, and tells you so. Every resource that could collide with the stack's is named `streamsec-ebs-scanner-**tf**-…`, deliberately distinct: `ecs:CreateCluster` is an upsert, so an identically named cluster is *silently adopted* rather than rejected, and a later `terraform destroy` would delete the cluster the live stack depends on. Set `allow_cloudformation_coexistence = true` to run both deliberately — each then scans every volume, and each one's retention sweep deletes snapshots tagged `Purpose=ebs-package-collector` account-wide, including the other's.

> **Registration is not wired up yet.** `streamsec_aws_scanner_ack` does not exist in any published provider release, so this module does not attempt it. The region still appears in the console — the scanner's own scan reports create the entry, stamped `deployed`, so the badge reads **Connected**. Two gaps until the provider ships it: `terraform destroy` never reports `uninstalled` and the stack metadata stays blank; and on a region ever touched from the console (including merely generating the template) the entry already exists, so scan reports only merge scan fields onto it and the install-state badge keeps whatever the console last set. On those regions ignore the badge and read the scan-status column.

> **First-time setup: run `terraform apply` twice.** Your Stream Security account must exist before this module can run.
> ```bash
> # Replace "account" with the name you gave the Stream Security account module
> terraform apply -target=module.account
> terraform apply
> ```

## What the console asks you for

The console template presents exactly eleven parameters. Each maps to one module input, with the same default:

| Console parameter | Module input | Default |
|---|---|---|
| `ScannerImage` | `scanner_image` | `public.ecr.aws/stream-security/volume-scanner:latest` |

`:latest` is re-resolved on every task launch, matching the console stack. The task role can snapshot and decrypt any volume in the region, so pin a digest (`...@sha256:...`) if your change control requires it.
| `ScannerRegion` | *(the `aws` provider's region)* | — |
| `ScanLanguagePackages` | `scan_language_packages` | `true` |
| `ScanDatabases` | `scan_databases` | `false` |
| `ScanAIWorkloads` | `scan_ai_workloads` | `false` |
| `ScanSecrets` | `scan_secrets` | `false` |
| `WorkloadKinds` | `workload_kinds` | `"lambda,ecs"` |
| `ShardSize` | `shard_size` | `100` |
| `MaxConcurrentShards` | `max_concurrent_shards` | `10` |
| `VpcId` | `vpc_id` | — (bring-your-own-network only) |
| `SubnetIds` | `subnet_ids` | — (bring-your-own-network only) |

`create_scanner_vpc` is the only input with no console parameter behind it: the console makes that choice when the template is *generated* (`create_network`), and a module has no generation step. `vpc_id` and `subnet_ids` are what it renders when the choice is "use my own network".

Every other input is one the CloudFormation template hardcodes, and its default here reproduces the template's value. **Setting nothing but the console parameters gives you the console's deployment**, with two intentional differences:

- **Resource names carry a `-tf` marker**, for the cluster-adoption reason above.
- **The public subnet does not auto-assign public IPs**, where the template sets `MapPublicIpOnLaunch: true`. Nothing is ever launched there — it holds the NAT gateway, which uses an Elastic IP — so the template's value buys nothing and trips CIS "ensure subnets do not auto-assign public IPs".

## Usage

One instance per account **and** region. Planning calls `ecs:ListClusters` to check for a CloudFormation-deployed scanner, so the deploying principal needs that permission.

```hcl
# Basic — dedicated VPC with a NAT gateway, scanning us-east-1
module "volume_scanner_us_east_1" {
  source      = "streamsec-terraform/aws-account//modules/volume-scanner"
  customer_id = "your-workspace-id"
  providers = {
    aws = aws.us-east-1
  }
  depends_on = [module.account]
}

# Run in your own private subnets instead of a module-managed VPC
module "volume_scanner_us_east_2" {
  source             = "streamsec-terraform/aws-account//modules/volume-scanner"
  customer_id        = "your-workspace-id"
  create_scanner_vpc = false
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_ids         = ["subnet-0123456789abcdef0"]
  providers = {
    aws = aws.us-east-2
  }
  depends_on = [module.account]
}
```

The optional scanners — `scan_secrets`, `scan_ai_workloads`, `scan_databases` — are off by default; set them to `true` to enable.

`customer_id` is the same value you set as `workspace_id` on the `streamsec` provider. `tenant_name` defaults to the first DNS label of the provider host; set it explicitly behind a shared endpoint, custom CNAME or PrivateLink DNS, or the scanner tags every SBOM with a tenant that does not exist and ingest drops them silently.

## Networking

By default (`create_scanner_vpc = true`) the module provisions a dedicated `10.255.0.0/24` VPC in one availability zone, split into two `/25`s: a public half holding only the NAT gateway, and a private half where the scanner runs with no public IP. **A NAT gateway costs roughly $32/month idle per region plus ~$0.045/GB processed** — a deliberate trade-off, since a public IP on the task fails SOC 2, CIS AWS Foundations and PCI-DSS baselines.

The NAT gateway's Elastic IP is stable across NAT replacements and exposed as the `nat_gateway_public_ip` output, so you can allowlist one egress IP instead of the whole Fargate range. Destroy-then-apply **releases** it and allocates a new one, staling that allowlist silently; an in-place `scanner_vpc_cidr` change keeps it.

The module also creates two **VPC endpoints** here: interface for `com.amazonaws.<region>.ebs`, gateway for S3. Snapshot block reads dominate the scanner's egress and NAT data processing costs ~4.5x the PrivateLink rate, so this took NAT inbound for one scan on a three-instance eu-west-1 fleet from **3,385 MiB to 122 MiB**. The interface endpoint adds ~$7.30/month; the S3 gateway endpoint is free. The image pull still goes via the NAT, since `public.ecr.aws` is CloudFront-fronted. Set `create_ebs_vpc_endpoint = false` where that EBS service is unavailable in your region or partition.

### Bring your own subnets

`create_scanner_vpc = false` with `vpc_id` + `subnet_ids` avoids a second NAT gateway. The module then creates **no** VPC endpoints — it does not own that VPC, and a second S3 gateway endpoint on a route table that already has one fails with `RouteAlreadyExists`. Add an EBS interface endpoint yourself for the same saving.

Each supplied subnet is validated for a `0.0.0.0/0` route to a **NAT gateway, NAT instance, inspection/firewall ENI, VPC endpoint, Transit Gateway, virtual private gateway, Cloud WAN core network, or Outposts local gateway** — the task has no public IP, so an Internet Gateway route is a black hole — plus membership in `vpc_id`, a standard availability zone (no Local Zones or Wavelength; Fargate is not offered there), an IPv4 CIDR, VPC DNS resolution, and enough addresses for the peak task count. A failure names the subnet and the reason, instead of an opaque `ResourceInitializationError` later.

Three limits of that check:

- **Only a literal `0.0.0.0/0` route counts.** A default route via a **managed prefix list** is rejected: its contents are not readable from the route table, and the commonest one in a private subnet is the S3 gateway endpoint. Set `validate_subnet_egress = false` if yours genuinely is a prefix list.
- **Capacity is judged from CIDR size, not free addresses, and from the smallest subnet, not the sum** — the free count drops while the scanner's own children run, and ECS placement is best-effort so the whole fan-out can land in one subnet. A large but busy shared subnet passes and can still exhaust at scan time.
- **A blackholed default route passes.** `aws_route_table` exposes no route state, so one whose NAT gateway was deleted still validates. The CloudFormation precheck catches this; this does not.

> **When these checks run.** Plan time — but only while Terraform can read the module's data sources. The `depends_on = [module.account]` in every example defers those reads whenever `module.account` has pending changes, moving the checks to **apply**, where a bad subnet leaves the secret, cluster, log group, IAM roles and EventBridge rule behind before failing. Applying the account module on its own first keeps them at plan time.

> **A VPC endpoint alone is not enough to reach Stream.** The egress check accepts a default route to a VPC endpoint, but SBOM upload goes to your tenant's **public** hostname and this module has no `enable_privatelink` support yet. Such a subnet passes validation and then times out on every upload.

If `subnet_ids` are created in the same apply (`module.vpc.private_subnets`, `aws_subnet.x[*].id`), the list length is unknown at plan and no `for_each`-keyed check can run. Set `validate_subnet_egress = false`; that disables **all** of the supplied-subnet checks above, and the subnets are used as given.

The VPC choice controls only the scanner's **egress**. It scans the whole account/region through the EBS Direct API regardless of where the scanned workloads live.

## Scanning schedule

One EventBridge rule fires the scanner daily at 03:00 UTC. The scanner is an orchestrator: it discovers instances and fans out one child Fargate task per shard, capped by `max_concurrent_shards`. The defaults (100 instances per shard, 10 concurrent) cover roughly 1000 instances per wave. Concurrency is bounded by task memory — Syft uses 250–400 MB per concurrent host scan, so raise `task_memory` first.

Each concurrent task takes one private IP. If you shrink `scanner_vpc_cidr`, the module checks at plan time that the private half still holds `max_concurrent_shards + 1` ENIs, plus one more when `workload_kinds` is set, against a count that also excludes the EBS endpoint ENI. The default `/24` has room to spare.

The module also fires **one immediate scan at apply time** so you don't wait for the first scheduled run. It retries the failures that clear on their own — chiefly IAM eventual consistency, the task's policies having been attached seconds earlier. Anything left is swallowed: the daily schedule is the fallback and the details land in the initial-scan Lambda's logs. Set `trigger_initial_scan = false` to skip it.

Override `schedule_expression` with a cron expression only. An EventBridge `rate(...)` rule fires at rule creation *as well as* on the interval, duplicating the first scan.

## Permissions granted

The collection token is injected through the task definition's `secrets` block from Secrets Manager, never as a plaintext environment variable — anything with `ecs:DescribeTaskDefinition`, including the scanner task role, can read that. It is **not** kept out of Terraform state: `aws_secretsmanager_secret_version` stores it in plaintext, so treat state as secret material. The secret name carries a random suffix, which is what makes destroy-then-apply work with a non-zero `secret_recovery_window_days`, so read it from the `collection_token_secret_name` / `collection_token_secret_arn` outputs.

The task role is least-privilege:

- read-only `ec2:Describe{Instances,Volumes,Snapshots}`
- `ec2:CreateSnapshot`, with tagging restricted to `Purpose = ebs-package-collector`
- `ec2:DeleteSnapshot` and EBS-direct block reads **only** on snapshots carrying that tag. The tag scopes access, it does not prove ownership: the value is a constant shared by every Stream deployment, so any principal holding `ec2:CreateTags` on snapshots can apply it to a snapshot you care about and have the next retention sweep delete it. Scope `ec2:CreateTags` accordingly — the scanner image sets the tag itself, so the value is not configurable here
- read-only Lambda, ECS and ECR access granted per `workload_kinds`: `"ecs"` gets no account-wide `lambda:GetFunction` (which returns function code **and each function's plaintext environment variables** — often where DB passwords live), `"lambda"` gets no account-wide ECS read, `""` removes all of them
- `ecs:RunTask` scoped to the scanner's own cluster
- for **encrypted** volumes, exactly `kms:Decrypt` and `kms:DescribeKey` and only via `kms:ViaService = ec2.<region>`, so the role cannot touch the same CMK when it protects S3, RDS or Secrets Manager. Matches the CloudFormation template exactly

### Encrypted volumes

Volumes on a **customer-managed CMK** need that key allowed in the scanner's identity policy, because a CMK's default key policy delegates authorisation to IAM. Without it the snapshot succeeds and every block read fails — reported as `ResourceNotFoundException: KMS key not found`, not access-denied — so the task exits, `terraform apply` reports success, the console shows the region healthy, and those instances silently return zero findings. Volumes on the AWS-managed `aws/ebs` key are unaffected, so the gap only bites accounts using their own CMKs.

`scan_encrypted_volumes` is therefore on by default with `kms_key_arns = ["*"]`, since customer CMK ARNs are not knowable at plan time. Narrow it if you can enumerate your region's EBS keys, or set it false to drop the grants and accept that encrypted instances go unscanned.

## Uninstalling

`terraform destroy` removes everything **provided no scan is running**. Scanner tasks are launched out of band, so Terraform has no dependency on them: a destroy overlapping a scan tears down the IAM policies, task definition, secret and log groups first, then fails on the cluster after 10 minutes and the subnets after 20 — leaving the VPC, NAT gateway and Elastic IP behind, and stripping the running orchestrator of the only permission that can delete the snapshots it created. Set `schedule_enabled = false`, apply, wait for tasks to drain, then destroy.

Nothing reports the region as uninstalled to Stream until the provider ships that resource, so the badge stays **Connected**; the scan status is the honest signal once heartbeats stop.

A failed apply is not rolled back either. One that fails after the NAT gateway exists leaves it and its Elastic IP billing until you `terraform destroy` or fix the input and re-apply.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3 |
| <a name="requirement_archive"></a> [archive](#requirement\_archive) | >= 2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.0 |
| <a name="requirement_streamsec"></a> [streamsec](#requirement\_streamsec) | >= 1.7 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_archive"></a> [archive](#provider\_archive) | >= 2.0 |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 6.0 |
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.0 |
| <a name="provider_streamsec"></a> [streamsec](#provider\_streamsec) | >= 1.7 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_event_rule.daily](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.daily](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_log_group.initial_scan](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_ecs_cluster.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_cluster) | resource |
| [aws_ecs_task_definition.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition) | resource |
| [aws_eip.nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip) | resource |
| [aws_iam_role.events](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.initial_scan](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.task](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.events](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.execution_secrets](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.initial_scan](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.orchestrator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.task](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.initial_scan_basic](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_internet_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/internet_gateway) | resource |
| [aws_lambda_function.initial_scan](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_invocation.initial_scan](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_invocation) | resource |
| [aws_nat_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/nat_gateway) | resource |
| [aws_route.private_nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route.public_internet](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route_table.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table_association.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_secretsmanager_secret.collection_token](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.collection_token](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_security_group.endpoints](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_subnet.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc) | resource |
| [aws_vpc_endpoint.ebs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_endpoint.s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_security_group_egress_rule.all](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.endpoints_https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [random_string.secret_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |
| [archive_file.initial_scan](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_ecs_clusters.existing](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ecs_clusters) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_route_table.byo_explicit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route_table) | data source |
| [aws_route_table.byo_main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route_table) | data source |
| [aws_route_tables.byo_explicit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route_tables) | data source |
| [aws_subnet.byo](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |
| [aws_vpc.byo](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |
| [aws_vpc_endpoint_service.ebs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc_endpoint_service) | data source |
| [aws_vpc_endpoint_service.s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc_endpoint_service) | data source |
| [streamsec_aws_account.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/aws_account) | data source |
| [streamsec_host.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/host) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_allow_cloudformation_coexistence"></a> [allow\_cloudformation\_coexistence](#input\_allow\_cloudformation\_coexistence) | Allow deploying alongside another scanner in the same region. Off by default: two scanners scan every volume twice and delete each other's snapshots. | `bool` | `false` | no |
| <a name="input_collection_token_secret_name"></a> [collection\_token\_secret\_name](#input\_collection\_token\_secret\_name) | Base name for the Secrets Manager secret holding the collection token. Region and a random suffix are appended. | `string` | `"streamsec-scanner-collection-token"` | no |
| <a name="input_create_ebs_vpc_endpoint"></a> [create\_ebs\_vpc\_endpoint](#input\_create\_ebs\_vpc\_endpoint) | Create the EBS Direct API interface endpoint so snapshot block reads bypass the NAT Gateway, which is the bulk of the scanner's egress. On by default when the module creates the VPC. Leave unset otherwise. | `bool` | `null` | no |
| <a name="input_create_scanner_vpc"></a> [create\_scanner\_vpc](#input\_create\_scanner\_vpc) | Create a dedicated VPC, subnets, Internet Gateway and NAT Gateway for the scanner. False to use your own private subnets. | `bool` | `true` | no |
| <a name="input_customer_id"></a> [customer\_id](#input\_customer\_id) | Stream Security workspace id — the same value as the provider's workspace\_id. A wrong value is silent: SBOMs are dropped by ingest and the region still looks healthy. | `string` | `null` | no |
| <a name="input_ephemeral_storage_size_gib"></a> [ephemeral\_storage\_size\_gib](#input\_ephemeral\_storage\_size\_gib) | Task ephemeral storage in GiB for the scanner's disk cache. Minimum 21. | `number` | `50` | no |
| <a name="input_kms_key_arns"></a> [kms\_key\_arns](#input\_kms\_key\_arns) | KMS keys the scanner may use for encrypted volumes. Narrow from ["*"] if you can enumerate your EBS keys. | `list(string)` | <pre>[<br/>  "*"<br/>]</pre> | no |
| <a name="input_log_retention_days"></a> [log\_retention\_days](#input\_log\_retention\_days) | Retention in days for the scanner log groups. Must be a CloudWatch retention value, or 0 to keep forever. | `number` | `30` | no |
| <a name="input_max_concurrent_shards"></a> [max\_concurrent\_shards](#input\_max\_concurrent\_shards) | Maximum child scanner tasks in flight at once. Each consumes one subnet IP address. | `number` | `10` | no |
| <a name="input_resource_prefix"></a> [resource\_prefix](#input\_resource\_prefix) | Prefix for all created resource names. Max 9 characters, letters/digits/hyphens — IAM role names consume the rest of the 64-char limit. | `string` | `""` | no |
| <a name="input_scan_ai_workloads"></a> [scan\_ai\_workloads](#input\_scan\_ai\_workloads) | Detect AI/ML framework installs and surface them as workload metadata. | `bool` | `false` | no |
| <a name="input_scan_databases"></a> [scan\_databases](#input\_scan\_databases) | Detect installed databases from their on-disk signatures. Adds a filesystem walk per instance. | `bool` | `false` | no |
| <a name="input_scan_encrypted_volumes"></a> [scan\_encrypted\_volumes](#input\_scan\_encrypted\_volumes) | Grant the KMS permissions needed to read snapshots of encrypted volumes. Off means those instances report no findings, with no error anywhere. | `bool` | `true` | no |
| <a name="input_scan_language_packages"></a> [scan\_language\_packages](#input\_scan\_language\_packages) | Detect language-level packages on disk (Python, Node, Ruby, Go, Rust, Java). The only toggle on by default. | `bool` | `true` | no |
| <a name="input_scan_secrets"></a> [scan\_secrets](#input\_scan\_secrets) | Detect secrets and credentials on disk. Significantly increases scan duration. | `bool` | `false` | no |
| <a name="input_scanner_image"></a> [scanner\_image](#input\_scanner\_image) | ECR image URI for the scanner. Not reachable from aws-cn — mirror it and override there. | `string` | `"public.ecr.aws/stream-security/volume-scanner:latest"` | no |
| <a name="input_scanner_vpc_cidr"></a> [scanner\_vpc\_cidr](#input\_scanner\_vpc\_cidr) | CIDR for the scanner VPC. Split in half: public for the NAT Gateway, private for the tasks. | `string` | `"10.255.0.0/24"` | no |
| <a name="input_schedule_enabled"></a> [schedule\_enabled](#input\_schedule\_enabled) | Enable the daily scan schedule. Set false to pause scanning — before a destroy, during an incident, or for a maintenance window. | `bool` | `true` | no |
| <a name="input_schedule_expression"></a> [schedule\_expression](#input\_schedule\_expression) | EventBridge schedule for the daily scan. Must be a six-field cron expression; rate(...) is rejected. | `string` | `"cron(0 3 * * ? *)"` | no |
| <a name="input_secret_recovery_window_days"></a> [secret\_recovery\_window\_days](#input\_secret\_recovery\_window\_days) | Days Secrets Manager waits before deleting the secret. 0, or 7-30. | `number` | `30` | no |
| <a name="input_shard_size"></a> [shard\_size](#input\_shard\_size) | Instances per child task. Lower means more parallelism; higher means fewer, longer-running children. | `number` | `100` | no |
| <a name="input_subnet_ids"></a> [subnet\_ids](#input\_subnet\_ids) | Existing private subnets for the scanner tasks, required when create\_scanner\_vpc is false. Add an EBS Direct API interface endpoint to your VPC to keep block reads off the NAT Gateway. | `list(string)` | `[]` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | A map of global tags to add to all created resources | `map(string)` | `{}` | no |
| <a name="input_task_cpu"></a> [task\_cpu](#input\_task\_cpu) | Fargate task CPU units. One of 256, 512, 1024, 2048, 4096, 8192, 16384. | `string` | `"4096"` | no |
| <a name="input_task_memory"></a> [task\_memory](#input\_task\_memory) | Fargate task memory in MiB. Raise before raising max\_concurrent\_shards. Must be valid for the chosen task\_cpu. | `string` | `"16384"` | no |
| <a name="input_tenant_name"></a> [tenant\_name](#input\_tenant\_name) | Stream Security tenant name. Defaults to the first DNS label of the provider host; set it explicitly behind a shared endpoint, custom CNAME or PrivateLink DNS. | `string` | `null` | no |
| <a name="input_trigger_initial_scan"></a> [trigger\_initial\_scan](#input\_trigger\_initial\_scan) | Run one immediate scan at apply time. Failures are swallowed; the daily schedule is the fallback. | `bool` | `true` | no |
| <a name="input_validate_subnet_egress"></a> [validate\_subnet\_egress](#input\_validate\_subnet\_egress) | Check supplied subnets for egress, VPC membership, zone and capacity. Set false when the subnet list length is unknown at plan; that disables all of those checks. | `bool` | `true` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | VPC for the scanner tasks, required when create\_scanner\_vpc is false. Used for egress only; the scan covers the whole region regardless. | `string` | `null` | no |
| <a name="input_workload_kinds"></a> [workload\_kinds](#input\_workload\_kinds) | Workloads to scan besides EC2: "lambda", "ecs", "lambda,ecs", or "" to disable. Also gates the matching IAM grants. | `string` | `"lambda,ecs"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_cluster_arn"></a> [cluster\_arn](#output\_cluster\_arn) | ARN of the ECS cluster running the scanner tasks |
| <a name="output_collection_token_secret_arn"></a> [collection\_token\_secret\_arn](#output\_collection\_token\_secret\_arn) | ARN of the Secrets Manager secret holding the scanner's collection token |
| <a name="output_collection_token_secret_name"></a> [collection\_token\_secret\_name](#output\_collection\_token\_secret\_name) | Name of the Secrets Manager secret holding the scanner's collection token. Carries a random suffix, so read it from here rather than reconstructing it. |
| <a name="output_log_group_name"></a> [log\_group\_name](#output\_log\_group\_name) | CloudWatch log group receiving the scanner container logs |
| <a name="output_nat_gateway_public_ip"></a> [nat\_gateway\_public\_ip](#output\_nat\_gateway\_public\_ip) | Stable egress IP of the scanner's NAT Gateway, for allowlisting in upstream firewalls. Null when create\_scanner\_vpc is false, since egress is then through infrastructure this module does not own. |
| <a name="output_scanner_subnet_ids"></a> [scanner\_subnet\_ids](#output\_scanner\_subnet\_ids) | Subnets the scanner Fargate tasks run in |
| <a name="output_scanner_vpc_id"></a> [scanner\_vpc\_id](#output\_scanner\_vpc\_id) | ID of the VPC the scanner runs in — the one this module created, or the vpc\_id that was supplied |
| <a name="output_security_group_id"></a> [security\_group\_id](#output\_security\_group\_id) | ID of the scanner's egress-only security group |
| <a name="output_task_definition_arn"></a> [task\_definition\_arn](#output\_task\_definition\_arn) | ARN of the scanner task definition (current revision) |
| <a name="output_task_definition_family_arn"></a> [task\_definition\_family\_arn](#output\_task\_definition\_family\_arn) | Revision-less family ARN of the scanner task definition — what the orchestrator uses to launch child tasks on the current ACTIVE revision |
| <a name="output_task_role_arn"></a> [task\_role\_arn](#output\_task\_role\_arn) | ARN of the IAM role the scanner task assumes |
<!-- END_TF_DOCS -->

## Tests

```bash
terraform test
```

Mock providers throughout, no AWS API calls. Requires Terraform >= 1.7 for `mock_provider`, stricter than the module's own `required_version` of 1.3.

### The one case `terraform test` cannot cover

Tests can only supply **known** values through `variables`, so they cannot reproduce the failure this module has shipped twice against a green suite: when `vpc_id`/`subnet_ids` come from resources created in the same apply, their values are unknown at plan while the list **length** is known, and any for-expression with an `if` predicate over them becomes wholly unknown — making the index-keyed `byo_subnets` map unknown and failing every bring-your-own validation with `Invalid for_each argument`.

After any change to `local.byo_vpc_id`, `local.byo_subnet_ids`, `local.byo_subnets`, or the data sources keyed off them, plan a throwaway root module. It must succeed; `Invalid for_each argument` means a filter has been reintroduced.

```hcl
resource "aws_vpc" "t" { cidr_block = "10.60.0.0/16" }

resource "aws_subnet" "private" {
  count      = 2                     # length known at plan, ids are not
  vpc_id     = aws_vpc.t.id
  cidr_block = cidrsubnet("10.60.0.0/16", 8, count.index)
}

module "scanner" {
  source             = "../.."
  customer_id        = "your-workspace-id"
  create_scanner_vpc = false
  vpc_id             = aws_vpc.t.id
  subnet_ids         = aws_subnet.private[*].id
}
```
