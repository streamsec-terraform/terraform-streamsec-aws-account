# terraform-streamsec-aws-account/volume-scanner

Terraform module for the Stream Agentless Scanner (EBS) — agentless vulnerability scanning of your EC2 instances, Lambda functions and Fargate task images.

A Fargate task runs on a schedule, snapshots EBS volumes, extracts SBOMs, and ships them to Stream Security for Grype-based CVE matching. No agents are installed on your instances, and Stream is granted no credentials in your account.

This is the Terraform equivalent of the CloudFormation stack the Stream console deploys from **Integrations → Vulnerability Scanners → Stream Agentless Scanner**. Deploy a region with one or the other, not both.

> **Migrating from the CloudFormation stack: delete it first.** The module refuses to apply while the console's CloudFormation scanner is still deployed in the region, and tells you so. Delete that stack, let it finish, then apply.
>
> Everything this module creates is named `streamsec-ebs-scanner-**tf**-…`, deliberately distinct from the stack's `streamsec-ebs-scanner-…`. That is a safety property, not cosmetics: `ecs:CreateCluster` is an upsert, so an identical cluster name is *silently adopted* rather than rejected, and a later `terraform destroy` would delete the cluster the live stack depends on.
>
> Set `allow_cloudformation_coexistence = true` to run both deliberately — but note they will each scan every volume, and each one's retention sweep deletes snapshots tagged `Purpose=ebs-package-collector` account-wide, including the other's.

> **Registration is not wired up yet.** The `streamsec_aws_scanner_ack` resource that reports install state back to Stream does not exist in any published provider release, so it is commented out in `ack.tf`. The region still appears in the console: the scanner's own progress reports create the entry on first scan, and a region Stream creates that way is stamped `deployed`, so the badge reads **Connected**. Two gaps remain until the provider ships the resource. First, `terraform destroy` does not report `uninstalled`, and the stack metadata (`stack_id`, `stack_region`, `deployed_at`) stays blank. Second, if the region was ever touched from the console — including merely generating the template, which records `pending` — the entry already exists, so the scanner's reports only merge scan fields onto it and the install-state badge keeps whatever the console last set (`pending`, `failed`, or `uninstalled`) indefinitely. On such a region, ignore the install-state badge and read the scan-status column, which the scanner does keep current. Uncomment the block once the provider ships it.

> **First-time setup: run `terraform apply` twice.**
> This module needs your Stream Security account to be set up before it can run. If you're deploying both for the first time in the same configuration, apply the account module first, then apply everything:
> ```bash
> # Replace "account" with the name you gave the Stream Security account module
> terraform apply -target=module.account
> terraform apply
> ```
> After that, normal `terraform apply` works as usual.

## Usage

The module is per account **and** region — deploy one instance per region you want scanned.

Planning calls `ecs:ListClusters` to check no CloudFormation-deployed scanner is already running in the region, so the deploying principal needs that permission.

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

# Turn on the optional scanners
module "volume_scanner_eu_west_1" {
  source            = "streamsec-terraform/aws-account//modules/volume-scanner"
  customer_id       = "your-workspace-id"
  scan_secrets      = true
  scan_ai_workloads = true
  scan_databases    = true
  providers = {
    aws = aws.eu-west-1
  }
  depends_on = [module.account]
}
```

`customer_id` is the same value you set as `workspace_id` on the `streamsec` provider. It becomes optional once the provider exposes it as a data source attribute.

`tenant_name` defaults to the first DNS label of the provider's host, which is right for a per-tenant hostname like `https://acme.streamsec.io`. If your console is reached through a shared or regional endpoint, a custom CNAME, or PrivateLink endpoint DNS, set `tenant_name` explicitly — otherwise the scanner tags every SBOM with a tenant that does not exist, ingest drops them, and you see zero findings with no error anywhere.

## Networking

By default (`create_scanner_vpc = true`) the module provisions a dedicated `10.255.0.0/24` VPC in a single availability zone, split into two `/25`s:

- **public** — holds the NAT gateway only, with auto-assign public IP off. No Fargate task ever runs here.
- **private** — where the scanner runs, with no public IP. Egress goes out through the NAT gateway's Elastic IP.

That Elastic IP is stable across NAT gateway replacements, so you can allowlist a single upstream egress IP instead of the whole Fargate range. It's exposed as the `nat_gateway_public_ip` output.

By default the module also creates two **VPC endpoints** in that VPC: an interface endpoint for `com.amazonaws.<region>.ebs` and a gateway endpoint for S3. Snapshot block reads are the scanner's dominant egress, and NAT data processing costs roughly 4.5x the PrivateLink rate for the same bytes. Measured on a three-instance fleet in eu-west-1, this took NAT inbound traffic for one scan from **3,385 MiB to 122 MiB — a 96% reduction** — with the scan result unchanged. The interface endpoint adds ~$7.30/month; the S3 gateway endpoint is free.

PrivateLink keeps those bytes off the NAT and off the public internet. It does not mean they stay inside your VPC — the endpoint ENI is the entry point to an AWS-managed service that lives outside it. The scanner's own image pull still egresses via the NAT, since `public.ecr.aws` is CloudFront-fronted.

Set `create_ebs_vpc_endpoint = false` if `com.amazonaws.<region>.ebs` is unavailable in your region or partition.

**A NAT gateway costs roughly $32/month idle per region, plus ~$0.045/GB processed.** That's a deliberate trade-off: running the scanner with a public IP fails SOC 2, CIS AWS Foundations and PCI-DSS baselines that flag public IPs on compute.

In bring-your-own-subnet mode the module creates **no** VPC endpoints — it does not own that VPC, and a second S3 gateway endpoint on a route table that already has one fails with `RouteAlreadyExists`. Add an interface endpoint for `com.amazonaws.<region>.ebs` to your own VPC to get the same saving.

To avoid the second NAT gateway, set `create_scanner_vpc = false` and supply `vpc_id` + `subnet_ids`. Each subnet must have a `0.0.0.0/0` route to a **NAT gateway, NAT instance, inspection/firewall appliance ENI, VPC endpoint, Transit Gateway, virtual private gateway (VPN / Direct Connect), Cloud WAN core network, or Outposts local gateway** — the scanner task launches with no public IP, so a public subnet routed through an Internet Gateway is a black hole. The module validates this at plan time and tells you exactly which subnet is wrong and why, rather than letting the task fail later with an opaque `ResourceInitializationError`.

> **When these checks run.** They are plan-time checks *when Terraform can read the module's data sources*. The `depends_on = [module.account]` wiring every example here uses makes Terraform defer those reads whenever `module.account` has pending changes — on a first apply, or any apply that also changes the account module — so the checks move to **apply** and a bad subnet can leave the secret, cluster, log group, IAM roles and EventBridge rule behind before failing. Applying the account module on its own first (see the two-step note above) keeps them at plan time.

If your `subnet_ids` are created in the same apply (`module.vpc.private_subnets`, `aws_subnet.x[*].id`), Terraform may not know the list length at plan time and the validation cannot be keyed off values that do not exist yet. Set `validate_subnet_egress = false` in that case; the subnets are used as given. Note that the flag switches off **both** supplied-subnet checks — the egress walk and the "is this subnet even in `vpc_id`" check — because a `for_each` over a list of unknown length is rejected whichever check it feeds.

> **A VPC endpoint alone is not enough to reach Stream.** The egress check accepts a subnet whose default route targets a VPC endpoint, but the scanner uploads SBOMs to your tenant's **public** hostname. Unlike `real-time-events` and `flow-logs`, this module has no `enable_privatelink` support yet, so a subnet with no internet path will pass validation and then time out on every upload. Until PrivateLink lands here, give the scanner a subnet with real egress.

Only a literal `0.0.0.0/0` route counts. A default route expressed as a **managed prefix list** is *not* accepted: a prefix list's contents are not readable from the route table, and the commonest one in a private subnet is the S3 gateway endpoint, which says nothing about internet access — accepting it let subnets with no internet path through. Likewise a `vpce-` gateway route is never internet egress. If your default route genuinely is a prefix list, set `validate_subnet_egress = false`.

The module also checks that the **smallest** supplied subnet is large enough for the peak ENI count — `max_concurrent_shards`, plus the orchestrator, plus one workload child when `workload_kinds` is set. It uses the subnet's **CIDR size**, not its current free-address count: the live count drops while the scanner's own children are running, which would refuse any apply that overlapped a scan. The minimum rather than the sum, because ECS placement across a subnet list is best-effort and the whole fan-out can land in one subnet.

The trade-off is that a large but heavily-used shared subnet passes this check and can still exhaust at scan time. Supplied subnets are also rejected if they sit in a Local Zone or Wavelength zone, where Fargate is not offered, or if they have no IPv4 CIDR.

One gap versus the CloudFormation precheck: the `aws_route_table` data source exposes no route *state*, so a blackholed default route — one whose NAT gateway was deleted — still passes validation.

The VPC choice only controls the scanner's **egress**. It scans the whole account/region through the EBS Direct API regardless of which VPC the scanned workloads live in.

## Scanning schedule

A single EventBridge rule fires the scanner daily at 03:00 UTC. The scanner is an orchestrator: it discovers instances and fans out one child Fargate task per shard, capped by `max_concurrent_shards`. The defaults (100 instances per shard, 10 concurrent) cover roughly 1000 instances per wave.

Each concurrent task takes one private IP in the scanner subnet. If you shrink `scanner_vpc_cidr`, the module checks at plan time that the private half still holds `max_concurrent_shards + 1` ENIs, rather than letting the fan-out die part-way through. The default `/24` holds the maximum concurrency with room to spare.

By default the module also fires **one immediate scan at apply time**, so you don't wait for the first scheduled run. The trigger retries the failures that clear on their own — chiefly IAM eventual consistency, since the policies the task needs were attached seconds earlier by the same apply. Anything left after that is swallowed: the daily schedule is the fallback, and the details land in the initial-scan Lambda's CloudWatch logs. Set `trigger_initial_scan = false` to skip it.

Use a cron expression if you override `schedule_expression`. An EventBridge `rate(...)` rule fires once at rule creation *as well as* on the interval, which would duplicate the first scan.

## Permissions granted

The collection token the scanner authenticates uploads with is stored in Secrets Manager and injected through the task definition's `secrets` block, never as a plaintext environment variable. That keeps it out of the task definition, which anything holding `ecs:DescribeTaskDefinition` can read — including the scanner task role itself. It does **not** keep it out of Terraform state: `aws_secretsmanager_secret_version` stores the value in state in plaintext, so treat your state file as secret material either way.

The secret's name carries a random suffix, so read it from the `collection_token_secret_name` / `collection_token_secret_arn` outputs rather than reconstructing it. That suffix is what makes `terraform destroy` followed by `terraform apply` work with a non-zero `secret_recovery_window_days`.

The task role is least-privilege:

- read-only `ec2:Describe{Instances,Volumes,Snapshots}`
- `ec2:CreateSnapshot`, with tagging restricted to `Purpose = ebs-package-collector`
- `ec2:DeleteSnapshot` and EBS-direct block reads **only** on snapshots carrying that tag, so the scanner cannot touch snapshots created by you or any other tool
- read-only Lambda, ECS and ECR access for workload scanning, granted per kind: `workload_kinds = "ecs"` gets no account-wide `lambda:GetFunction` (which downloads function code) and `workload_kinds = "lambda"` gets no account-wide ECS task/task-definition read. Setting it to `""` removes all of them — it does not merely stop using them
- `ecs:RunTask` scoped to the scanner's own cluster, so none of these roles can launch the task into another cluster in the account
- KMS access for **encrypted** EBS volumes: `kms:Decrypt`, `kms:DescribeKey`, `kms:GenerateDataKeyWithoutPlaintext`, `kms:ReEncryptFrom/To`, plus `kms:CreateGrant` conditioned on `kms:GrantIsForAWSResource` so the role cannot mint grants of its own

### Encrypted volumes

Volumes encrypted with a **customer-managed CMK** need the scanner's identity policy to allow that key. A CMK's default key policy delegates authorisation to IAM, so the EBS direct API rejects the block reads without it — and it reports the rejection as `ResourceNotFoundException: KMS key not found`, not as an access-denied. Without the grants the scanner snapshots the volume successfully and then fails every block read: the task exits, `terraform apply` reports success, the console shows the region healthy, and you see zero findings for those instances.

Volumes encrypted with the **AWS-managed `aws/ebs` key** scan fine without these grants — that key policy grants account principals directly. So the gap only bites accounts using their own CMKs, which is most regulated ones.

`scan_encrypted_volumes` is therefore **on by default**. It defaults to `kms_key_arns = ["*"]` because customer CMK ARNs are not knowable at plan time; narrow it to your region's EBS keys if you can enumerate them, or set `scan_encrypted_volumes = false` to drop the grants entirely and accept that encrypted instances go unscanned.

## If an apply fails partway

Terraform does not roll back. An apply that fails after the NAT gateway exists leaves it — and its Elastic IP — billing until you clean up, where the CloudFormation stack would have self-cleaned. Run `terraform destroy`, or fix the input and re-apply.

## Uninstalling

`terraform destroy` removes everything in your account. It does not yet report the region as uninstalled to Stream — that happens once the `streamsec_aws_scanner_ack` block in `ack.tf` is enabled. Until then the region keeps the green **Connected** install-state badge its first scan report set, even though nothing is deployed; the *scan* status is the honest signal — it goes stale once the heartbeats stop.

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
| <a name="input_schedule_expression"></a> [schedule\_expression](#input\_schedule\_expression) | EventBridge schedule for the daily scan. Must be a six-field cron expression; rate(...) is rejected. | `string` | `"cron(0 3 * * ? *)"` | no |
| <a name="input_secret_recovery_window_days"></a> [secret\_recovery\_window\_days](#input\_secret\_recovery\_window\_days) | Days Secrets Manager waits before deleting the secret. 0, or 7-30. | `number` | `0` | no |
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

## Raising throughput

`max_concurrent_shards` is capped by task memory: Syft uses 250–400 MB per concurrent host scan, so raise `task_memory` before raising concurrency. Increasing concurrency also raises EBS Direct API call volume and Fargate launch throughput.

## Tests

```bash
terraform test
```

### The one case `terraform test` cannot cover

`terraform test` can only supply **known** values through `variables`, so it cannot reproduce the failure mode this module has shipped twice:

> `vpc_id` and `subnet_ids` come from resources created in the same apply, so their values are unknown at plan while the list **length** is known. Any for-expression carrying an `if` predicate over those values becomes wholly unknown, which makes the index-keyed `byo_subnets` map unknown and fails every bring-your-own validation with `Invalid for_each argument`.

Both times it was invisible to a fully green suite. **Reproduce it with a throwaway root module** after any change to `local.byo_vpc_id`, `local.byo_subnet_ids`, `local.byo_subnets`, or the data sources keyed off them:

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

`terraform plan` must succeed. If it reports `Invalid for_each argument`, a filter has been reintroduced into one of those locals.

Requires Terraform >= 1.7 for `mock_provider` — stricter than the module's own `required_version` of 1.3. The tests use mock providers throughout and make no AWS API calls.
