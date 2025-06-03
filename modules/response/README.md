# terraform-streamsec-aws-account/real-time-events
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 3.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.0 |
| <a name="requirement_streamsec"></a> [streamsec](#requirement\_streamsec) | >= 1.12 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 3.0 |
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.0 |
| <a name="provider_streamsec"></a> [streamsec](#provider\_streamsec) | >= 1.12 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_iam_role.response](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.response_roles](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.response](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.response_policies](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_ssm_document.response](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_document) | resource |
| [random_string.external_id](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |
| [streamsec_aws_response_ack.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/resources/aws_response_ack) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [streamsec_aws_account.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/aws_account) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_response_policy_name"></a> [response\_policy\_name](#input\_response\_policy\_name) | The name of the response policy | `string` | `"stream-security-response-policy"` | no |
| <a name="input_response_role_name"></a> [response\_role\_name](#input\_response\_role\_name) | The name of the response role | `string` | `"stream-security-response-role"` | no |
| <a name="input_runbooks_prefix"></a> [runbooks\_prefix](#input\_runbooks\_prefix) | The prefix for the runbooks | `string` | `""` | no |
| <a name="input_streamsec_account"></a> [streamsec\_account](#input\_streamsec\_account) | The AWS Account ID for the Stream.Security account. | `string` | `"624907860825"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | A map of global tags to add to all created resources | `map(string)` | `{}` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->
