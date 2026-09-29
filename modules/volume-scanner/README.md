# terraform-streamsec-aws-account/volume-scanner

Terraform module for the Stream Agentless Scanner. It scans your EC2 instances, Lambda functions and Fargate task images for vulnerabilities, with no agents on your instances and no credentials given to Stream Security.

A Fargate task runs on a schedule (daily by default), snapshots your EBS volumes, reads the installed packages and sends them to Stream Security. Old snapshots are cleaned up automatically. Deploy one module instance per region you want scanned.

This is the Terraform alternative to the CloudFormation stack in the console (**Integrations → Vulnerability Scanners → Stream Agentless Scanner**). Use one or the other in a region, not both. If the console stack is already deployed in a region, delete it first; the module stops with an error until you do.

> **First-time setup: run `terraform apply` twice.** Your Stream Security account must exist before this module can run.
> ```bash
> # Replace "account" with the name you gave the Stream Security account module
> terraform apply -target=module.account
> terraform apply
> ```

## Usage

```hcl
# Basic: the module creates a small dedicated VPC for the scanner
module "volume_scanner_us_east_1" {
  source      = "streamsec-terraform/aws-account/streamsec//modules/volume-scanner"
  customer_id = "your-workspace-id"
  providers = {
    aws = aws.us-east-1
  }
  depends_on = [module.account]
}

# Run the scanner in your own private subnets instead
module "volume_scanner_us_east_2" {
  source             = "streamsec-terraform/aws-account/streamsec//modules/volume-scanner"
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

`customer_id` is the same value as `workspace_id` on the `streamsec` provider.

Optional scans for secrets, AI/ML frameworks and databases are off by default. Turn them on with `scan_secrets`, `scan_ai_workloads` and `scan_databases`.

## Good to know

- **Networking.** By default the module creates a VPC with a NAT gateway (about $32/month per region), and the scanner runs with no public IP. To avoid the extra NAT gateway, use your own private subnets. They need a default route to a NAT gateway or similar egress, and the module checks this at plan time. If the subnets are created in the same apply, set `validate_subnet_egress = false`.
- **Egress IP.** The `nat_gateway_public_ip` output is the scanner's fixed outbound IP, if you need to allowlist it.
- **Encrypted volumes.** Volumes encrypted with your own KMS keys are scanned by default. To limit which keys the scanner can use, set `kms_key_arns`.
- **Serverless only.** Set `scan_workload_only = true` to scan only Lambda functions and Fargate task images, without snapshotting EC2 volumes.
- **Uninstalling.** Set `schedule_enabled = false` and apply, wait for any running scan to finish, then run `terraform destroy`. The region may still show as connected in the console afterwards.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3 |
| <a name="requirement_archive"></a> [archive](#requirement\_archive) | >= 2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |
| <a name="requirement_streamsec"></a> [streamsec](#requirement\_streamsec) | >= 1.7 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_archive"></a> [archive](#provider\_archive) | >= 2.0 |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 6.0 |
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
| <a name="input_collection_token_secret_name"></a> [collection\_token\_secret\_name](#input\_collection\_token\_secret\_name) | Prefix for the Secrets Manager secret holding the collection token. Region and a unique suffix are appended. | `string` | `"streamsec-scanner-collection-token"` | no |
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
| <a name="input_scan_workload_only"></a> [scan\_workload\_only](#input\_scan\_workload\_only) | Scan only the workloads in workload\_kinds and skip EC2 instance disks: no snapshots, no volume reads. Containers on EC2-launch-type ECS are then not scanned. Requires a non-empty workload\_kinds. | `bool` | `false` | no |
| <a name="input_scanner_image"></a> [scanner\_image](#input\_scanner\_image) | ECR image URI for the scanner. Not reachable from aws-cn — mirror it and override there. | `string` | `"public.ecr.aws/stream-security/volume-scanner:latest"` | no |
| <a name="input_scanner_vpc_cidr"></a> [scanner\_vpc\_cidr](#input\_scanner\_vpc\_cidr) | CIDR for the scanner VPC. Split in half: public for the NAT Gateway, private for the tasks. | `string` | `"10.255.0.0/24"` | no |
| <a name="input_schedule_enabled"></a> [schedule\_enabled](#input\_schedule\_enabled) | Enable the daily scan schedule. Set false to pause scanning — before a destroy, during an incident, or for a maintenance window. | `bool` | `true` | no |
| <a name="input_schedule_expression"></a> [schedule\_expression](#input\_schedule\_expression) | EventBridge schedule for the scan, daily by default. Must be a six-field cron expression; rate(...) is rejected. | `string` | `"cron(0 3 * * ? *)"` | no |
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
| <a name="output_collection_token_secret_name"></a> [collection\_token\_secret\_name](#output\_collection\_token\_secret\_name) | Name of the Secrets Manager secret holding the scanner's collection token. Carries a generated suffix, so read it from here rather than reconstructing it. |
| <a name="output_log_group_name"></a> [log\_group\_name](#output\_log\_group\_name) | CloudWatch log group receiving the scanner container logs |
| <a name="output_nat_gateway_public_ip"></a> [nat\_gateway\_public\_ip](#output\_nat\_gateway\_public\_ip) | Stable egress IP of the scanner's NAT Gateway, for allowlisting in upstream firewalls. Null when create\_scanner\_vpc is false, since egress is then through infrastructure this module does not own. |
| <a name="output_scanner_subnet_ids"></a> [scanner\_subnet\_ids](#output\_scanner\_subnet\_ids) | Subnets the scanner Fargate tasks run in |
| <a name="output_scanner_vpc_id"></a> [scanner\_vpc\_id](#output\_scanner\_vpc\_id) | ID of the VPC the scanner runs in — the one this module created, or the vpc\_id that was supplied |
| <a name="output_security_group_id"></a> [security\_group\_id](#output\_security\_group\_id) | ID of the scanner's egress-only security group |
| <a name="output_task_definition_arn"></a> [task\_definition\_arn](#output\_task\_definition\_arn) | ARN of the scanner task definition (current revision) |
| <a name="output_task_definition_family_arn"></a> [task\_definition\_family\_arn](#output\_task\_definition\_family\_arn) | Revision-less family ARN of the scanner task definition — what the orchestrator uses to launch child tasks on the current ACTIVE revision |
| <a name="output_task_role_arn"></a> [task\_role\_arn](#output\_task\_role\_arn) | ARN of the IAM role the scanner task assumes |
<!-- END_TF_DOCS -->
