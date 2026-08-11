# terraform-streamsec-aws-account/volume-scanner

Terraform module for the Stream Agentless Scanner (EBS) — agentless vulnerability scanning of your EC2 instances, Lambda functions and Fargate task images.

A Fargate task runs on a schedule, snapshots EBS volumes, extracts SBOMs, and ships them to Stream Security for Grype-based CVE matching. No agents are installed on your instances, and Stream is granted no credentials in your account.

This is the Terraform equivalent of the CloudFormation stack the Stream console deploys from **Integrations → Vulnerability Scanners → Stream Agentless Scanner**. Deploy a region with one or the other, not both.

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

**A NAT gateway costs roughly $32/month idle per region, plus ~$0.045/GB processed.** That's a deliberate trade-off: running the scanner with a public IP fails SOC 2, CIS AWS Foundations and PCI-DSS baselines that flag public IPs on compute.

To avoid the second NAT gateway, set `create_scanner_vpc = false` and supply `vpc_id` + `subnet_ids`. Each subnet must have a `0.0.0.0/0` route to a **NAT gateway, NAT instance, inspection/firewall appliance ENI, VPC endpoint, Transit Gateway, Cloud WAN core network, or Outposts local gateway** — the scanner task launches with no public IP, so a public subnet routed through an Internet Gateway is a black hole. The module validates this at plan time and tells you exactly which subnet is wrong and why, rather than letting the task fail later with an opaque `ResourceInitializationError`.

If your `subnet_ids` are created in the same apply (`module.vpc.private_subnets`, `aws_subnet.x[*].id`), Terraform may not know the list length at plan time and the validation cannot be keyed off values that do not exist yet. Set `validate_subnet_egress = false` in that case; the subnets are used as given. Note that the flag switches off **both** supplied-subnet checks — the egress walk and the "is this subnet even in `vpc_id`" check — because a `for_each` over a list of unknown length is rejected whichever check it feeds.

One gap versus the CloudFormation precheck: the `aws_route_table` data source exposes no route *state*, so a blackholed default route — one whose NAT gateway was deleted — still passes validation.

The VPC choice only controls the scanner's **egress**. It scans the whole account/region through the EBS Direct API regardless of which VPC the scanned workloads live in.

## Scanning schedule

A single EventBridge rule fires the scanner daily at 03:00 UTC. The scanner is an orchestrator: it discovers instances and fans out one child Fargate task per shard, capped by `max_concurrent_shards`. The defaults (100 instances per shard, 10 concurrent) cover roughly 1000 instances per wave.

Each concurrent task takes one private IP in the scanner subnet. If you shrink `scanner_vpc_cidr`, the module checks at plan time that the private half still holds `max_concurrent_shards + 1` ENIs, rather than letting the fan-out die part-way through. The default `/24` holds the maximum concurrency with room to spare.

By default the module also fires **one immediate scan at apply time**, so you don't wait for the first scheduled run. The trigger retries the failures that clear on their own — chiefly IAM eventual consistency, since the policies the task needs were attached seconds earlier by the same apply. Anything left after that is swallowed: the daily schedule is the fallback, and the details land in the initial-scan Lambda's CloudWatch logs. Set `trigger_initial_scan = false` to skip it.

Use a cron expression if you override `schedule_expression`. An EventBridge `rate(...)` rule fires once at rule creation *as well as* on the interval, which would duplicate the first scan.

## Permissions granted

The collection token the scanner authenticates uploads with is stored in Secrets Manager and injected through the task definition's `secrets` block, never as a plaintext environment variable. That keeps it out of the task definition, which anything holding `ecs:DescribeTaskDefinition` can read — including the scanner task role itself. It does **not** keep it out of Terraform state: `aws_secretsmanager_secret_version` stores the value in state in plaintext, so treat your state file as secret material either way.

The task role is least-privilege:

- read-only `ec2:Describe{Instances,Volumes,Snapshots}`
- `ec2:CreateSnapshot`, with tagging restricted to `Purpose = ebs-package-collector`
- `ec2:DeleteSnapshot` and EBS-direct block reads **only** on snapshots carrying that tag, so the scanner cannot touch snapshots created by you or any other tool
- read-only Lambda, ECS and ECR access for workload scanning, granted per kind: `workload_kinds = "ecs"` gets no account-wide `lambda:GetFunction` (which downloads function code) and `workload_kinds = "lambda"` gets no account-wide ECS task/task-definition read. Setting it to `""` removes all of them — it does not merely stop using them
- `ecs:RunTask` scoped to the scanner's own cluster, so none of these roles can launch the task into another cluster in the account

## Uninstalling

`terraform destroy` removes everything in your account. It does not yet report the region as uninstalled to Stream — that happens once the `streamsec_aws_scanner_ack` block in `ack.tf` is enabled. Until then the region keeps the green **Connected** install-state badge its first scan report set, even though nothing is deployed; the *scan* status is the honest signal — it goes stale once the heartbeats stop.

## Inputs

| Name | Description | Type | Default |
|------|-------------|------|---------|
| `customer_id` | Stream Security customer/workspace id — the same value as the provider's `workspace_id` | `string` | `null` |
| `scanner_image` | ECR image URI for the scanner | `string` | `public.ecr.aws/stream-security/volume-scanner:latest` |
| `scan_language_packages` | Detect language-level packages (Python, Node, Ruby, Go, Rust, Java) | `bool` | `true` |
| `scan_databases` | Detect installed databases | `bool` | `false` |
| `scan_ai_workloads` | Detect AI/ML frameworks | `bool` | `false` |
| `scan_secrets` | Detect secrets and credentials on disk | `bool` | `false` |
| `workload_kinds` | Serverless/container workloads to scan: `""`, `lambda`, `ecs`, `lambda,ecs` | `string` | `lambda,ecs` |
| `shard_size` | Instances per child task | `number` | `100` |
| `max_concurrent_shards` | Max child tasks in flight | `number` | `10` |
| `task_cpu` | Fargate task CPU units | `string` | `4096` |
| `task_memory` | Fargate task memory in MiB | `string` | `16384` |
| `ephemeral_storage_size_gib` | Task ephemeral storage for the disk cache | `number` | `50` |
| `create_scanner_vpc` | Provision a dedicated VPC with a NAT gateway | `bool` | `true` |
| `scanner_vpc_cidr` | CIDR for the scanner VPC | `string` | `10.255.0.0/24` |
| `tenant_name` | Stream tenant name; defaults to the first label of the provider host | `string` | `null` |
| `vpc_id` | Existing VPC, required when `create_scanner_vpc = false` | `string` | `null` |
| `subnet_ids` | Existing private subnets, required when `create_scanner_vpc = false` | `list(string)` | `[]` |
| `validate_subnet_egress` | Check supplied subnets have a default route at plan time | `bool` | `true` |
| `collection_token_secret_name` | Base name for the Secrets Manager secret holding the collection token | `string` | `streamsec-scanner-collection-token` |
| `secret_recovery_window_days` | Days before Secrets Manager deletes the secret | `number` | `0` |
| `schedule_expression` | EventBridge schedule for the scan; must be `cron(...)` | `string` | `cron(0 3 * * ? *)` |
| `trigger_initial_scan` | Run one immediate scan at apply time | `bool` | `true` |
| `log_retention_days` | CloudWatch log retention | `number` | `30` |
| `resource_prefix` | Prefix prepended to resource names, max 9 chars (IAM's 64-char role-name limit) | `string` | `""` |
| `tags` | Global tags added to all created resources | `map(string)` | `{}` |

## Outputs

| Name | Description |
|------|-------------|
| `cluster_arn` | ARN of the ECS cluster running the scanner |
| `task_definition_arn` | ARN of the scanner task definition (current revision) |
| `task_definition_family_arn` | Revision-less family ARN used by the orchestrator |
| `log_group_name` | CloudWatch log group receiving scanner logs |
| `security_group_id` | ID of the egress-only security group |
| `task_role_arn` | ARN of the scanner task role |
| `scanner_vpc_id` | VPC the scanner runs in |
| `scanner_subnet_ids` | Subnets the scanner tasks run in |
| `nat_gateway_public_ip` | Stable egress IP to allowlist upstream (null in bring-your-own-subnet mode) |

## Raising throughput

`max_concurrent_shards` is capped by task memory: Syft uses 250–400 MB per concurrent host scan, so raise `task_memory` before raising concurrency. Increasing concurrency also raises EBS Direct API call volume and Fargate launch throughput.

## Tests

```bash
terraform test
```

Requires Terraform >= 1.7 for `mock_provider` — stricter than the module's own `required_version` of 1.3. The tests use mock providers throughout and make no AWS API calls.
