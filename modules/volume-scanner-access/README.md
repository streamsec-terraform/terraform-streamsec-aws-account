# terraform-streamsec-aws-account/volume-scanner-access

Lets the Stream Agentless Scanner in another AWS account, the **hub**, scan this account. It creates one IAM role, `StreamScannerSpokeRole`, which only the hub account's scanner roles can assume (matched by name, with the hub's external id), and tells Stream Security when the role is created or removed. IAM is global, so deploy it once per account, not per region. The hub covers this account in the regions where the hub's scanner runs.

This is the Terraform twin of the CloudFormation access stack (or StackSet) the console offers for a hub. **Both create a role named `StreamScannerSpokeRole`, so use one or the other in an account**: the second fails with `EntityAlreadyExists`. To move an account from the stack to this module, delete the stack first; the hub can't scan the account until the module is applied.

How the hub, its coverage and its spokes fit together, in Terraform and in the console: [Scanning other accounts](../volume-scanner/README.md#scanning-other-accounts-hub-and-spoke).

## Before you start

- This account and the hub's are both integrated with Stream Security.
- The hub's scanner is deployed: [`modules/volume-scanner`](../volume-scanner) 1.16.0 or later, or the console's scanner stack.
- The hub scans this account: set in the console, or with the `streamsec_aws_scanner_hub` resource. Stream Security creates the hub's external id when the account becomes a hub; until then the plan fails reading `streamsec_aws_scanner_hub_access`.

## Usage

```hcl
module "scanner_access" {
  source         = "streamsec-terraform/aws-account/streamsec//modules/volume-scanner-access"
  hub_account_id = data.streamsec_aws_account.hub.id
  providers = {
    aws = aws.spoke
  }
}
```

`hub_account_id` is the hub's Stream Security id, the `id` of its `streamsec_aws_account`, not its 12-digit AWS account id. The `aws` provider must point at the account to be scanned. [`examples/volume-scanner-hub`](../../examples/volume-scanner-hub) deploys a hub and a spoke together.

## What it creates

- **The role `StreamScannerSpokeRole`**, with no path and one-hour sessions. Its trust admits the hub account only, with the hub's external id, and only the hub's scanner roles: one `aws:PrincipalArn` pattern per role name Stream Security returns, today the console scanner's `streamsec-scanner-*` and the volume-scanner module's `*streamsec-ebs-scanner-tf-*`. The external id and patterns are read at every plan, so the trust follows a change at the next apply.
- **The inline policy `StreamScannerAccess`**, statement for statement the console access stack's: read EC2 metadata, snapshot volumes and read or delete only the snapshots the scanner tagged, decrypt them through EC2 with customer-managed KMS keys whose policy delegates to IAM, and read Lambda functions, ECS tasks and their ECR images.
- **`streamsec_aws_scanner_access_ack`**, which tells Stream Security the access exists. `terraform destroy` reports it removed.

## Good to know

- **Encrypted volumes.** A KMS key whose key policy does not delegate to IAM (a restrictive custom policy, or a key in another account) must grant `StreamScannerSpokeRole` itself.
- **Removing access.** Remove the account from the hub's coverage, then destroy this module. The hub stops scanning the account at its next scan.

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
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.0 |
| <a name="provider_streamsec"></a> [streamsec](#provider\_streamsec) | >= 1.14.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [streamsec_aws_scanner_access_ack.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/resources/aws_scanner_access_ack) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [streamsec_aws_scanner_hub_access.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/aws_scanner_hub_access) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_hub_account_id"></a> [hub\_account\_id](#input\_hub\_account\_id) | Stream Security id of the hub: the integrated AWS account whose volume scanner scans this one (streamsec\_aws\_account's id, not the 12-digit AWS account id). | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | A map of additional tags to add to the IAM role | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_hub_cloud_account_id"></a> [hub\_cloud\_account\_id](#output\_hub\_cloud\_account\_id) | 12-digit id of the hub's AWS account, the only account the role trusts |
| <a name="output_role_arn"></a> [role\_arn](#output\_role\_arn) | ARN of StreamScannerSpokeRole, the role the hub's scanner assumes to scan this account |
| <a name="output_role_name"></a> [role\_name](#output\_role\_name) | Name of the role the hub's scanner assumes: always StreamScannerSpokeRole |
<!-- END_TF_DOCS -->
