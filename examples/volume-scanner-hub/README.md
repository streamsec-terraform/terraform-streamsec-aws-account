# Volume scanner hub and spoke

One AWS account, the hub, runs the Stream Agentless Scanner in `us-east-1` and also scans a second account, the spoke:

1. `module.hub_scanner` deploys the scanner in the hub account ([`modules/volume-scanner`](../../modules/volume-scanner)).
2. `streamsec_aws_scanner_hub.this` makes the hub scan the spoke. Stream Security gives the hub its external id here.
3. `module.spoke_access` creates `StreamScannerSpokeRole` in the spoke ([`modules/volume-scanner-access`](../../modules/volume-scanner-access)), trusting the hub's scanner with that external id.

Both accounts must already be integrated with Stream Security. Each spoke needs its own `aws` provider alias and access module block. For more regions, more spokes, and how this replaces the console's StackSets, see [Many regions and accounts](../../modules/volume-scanner/README.md#many-regions-and-accounts). For how the pieces fit together, see [Scanning other accounts](../../modules/volume-scanner/README.md#scanning-other-accounts-hub-and-spoke).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.0 |
| <a name="requirement_streamsec"></a> [streamsec](#requirement\_streamsec) | >= 1.14.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws.hub"></a> [aws.hub](#provider\_aws.hub) | >= 6.0 |
| <a name="provider_aws.spoke"></a> [aws.spoke](#provider\_aws.spoke) | >= 6.0 |
| <a name="provider_streamsec"></a> [streamsec](#provider\_streamsec) | >= 1.14.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_hub_scanner"></a> [hub\_scanner](#module\_hub\_scanner) | ../../modules/volume-scanner | n/a |
| <a name="module_spoke_access"></a> [spoke\_access](#module\_spoke\_access) | ../../modules/volume-scanner-access | n/a |

## Resources

| Name | Type |
|------|------|
| [streamsec_aws_scanner_hub.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/resources/aws_scanner_hub) | resource |
| [aws_caller_identity.hub](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_caller_identity.spoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [streamsec_aws_account.hub](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/aws_account) | data source |
| [streamsec_aws_account.spoke](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/aws_account) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_spoke_admin_role_arn"></a> [spoke\_admin\_role\_arn](#input\_spoke\_admin\_role\_arn) | A role in the spoke account that may create IAM roles, for Terraform to assume | `string` | n/a | yes |
| <a name="input_workspace_id"></a> [workspace\_id](#input\_workspace\_id) | Stream Security workspace id, the same value as the streamsec provider's workspace\_id | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_hub_task_role_arn"></a> [hub\_task\_role\_arn](#output\_hub\_task\_role\_arn) | The hub scanner's task role, which the spoke role trusts |
| <a name="output_spoke_role_arn"></a> [spoke\_role\_arn](#output\_spoke\_role\_arn) | The role the hub's scanner assumes in the spoke account |
<!-- END_TF_DOCS -->
