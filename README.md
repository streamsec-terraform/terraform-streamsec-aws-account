# terraform-streamsec-aws-account
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 3.0 |
| <a name="requirement_streamsec"></a> [streamsec](#requirement\_streamsec) | >= 1.5 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 3.0 |
| <a name="provider_streamsec"></a> [streamsec](#provider\_streamsec) | >= 1.5 |
| <a name="provider_time"></a> [time](#provider\_time) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_cloudtrail.streamsec_cloudtrail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudtrail) | resource |
| [aws_iam_policy.streamsec_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.streamsec_policy_attachment](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_s3_bucket.streamsec_cloudtrail_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_policy.s3_cloudtrail_policy_attachment](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [streamsec_aws_account.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/resources/aws_account) | resource |
| [streamsec_aws_account_ack.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/resources/aws_account_ack) | resource |
| [time_sleep.wait](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_aws_account_display_name"></a> [aws\_account\_display\_name](#input\_aws\_account\_display\_name) | The display name for the AWS account to be protected by Stream.Security. | `string` | n/a | yes |
| <a name="input_aws_account_regions"></a> [aws\_account\_regions](#input\_aws\_account\_regions) | The AWS regions for the AWS account to be protected by Stream.Security. | `list(string)` | n/a | yes |
| <a name="input_cloudtrail_bucket_force_destroy"></a> [cloudtrail\_bucket\_force\_destroy](#input\_cloudtrail\_bucket\_force\_destroy) | A boolean that indicates all objects should be deleted from the bucket so that the bucket can be destroyed without error | `bool` | `true` | no |
| <a name="input_cloudtrail_bucket_name"></a> [cloudtrail\_bucket\_name](#input\_cloudtrail\_bucket\_name) | The name of the S3 bucket to store CloudTrail logs in | `string` | `"streamsec-cloudtrail"` | no |
| <a name="input_cloudtrail_bucket_tags"></a> [cloudtrail\_bucket\_tags](#input\_cloudtrail\_bucket\_tags) | tags for cloudtrail bucket | `map(string)` | `{}` | no |
| <a name="input_cloudtrail_bucket_use_name_prefix"></a> [cloudtrail\_bucket\_use\_name\_prefix](#input\_cloudtrail\_bucket\_use\_name\_prefix) | Determines whether the CloudTrail bucket name (`cloudtrail_bucket_name`) is used as a prefix | `bool` | `true` | no |
| <a name="input_cloudtrail_name"></a> [cloudtrail\_name](#input\_cloudtrail\_name) | Name of the CloudTrail to create | `string` | `"streamsec-real-time-cloudtrail"` | no |
| <a name="input_cloudtrail_tags"></a> [cloudtrail\_tags](#input\_cloudtrail\_tags) | tags for cloudtrail | `map(string)` | `{}` | no |
| <a name="input_create_cloudtrail"></a> [create\_cloudtrail](#input\_create\_cloudtrail) | Whether to create a CloudTrail for the AWS account | `bool` | `false` | no |
| <a name="input_iam_policy_description"></a> [iam\_policy\_description](#input\_iam\_policy\_description) | Description to use on IAM policy created | `string` | `"Stream Security IAM Policy"` | no |
| <a name="input_iam_policy_name"></a> [iam\_policy\_name](#input\_iam\_policy\_name) | Name to use on IAM policy created | `string` | `"streamsec-policy"` | no |
| <a name="input_iam_policy_path"></a> [iam\_policy\_path](#input\_iam\_policy\_path) | IAM policy path | `string` | `null` | no |
| <a name="input_iam_policy_tags"></a> [iam\_policy\_tags](#input\_iam\_policy\_tags) | A map of additional tags to add to the IAM policy created | `map(string)` | `{}` | no |
| <a name="input_iam_policy_use_name_prefix"></a> [iam\_policy\_use\_name\_prefix](#input\_iam\_policy\_use\_name\_prefix) | Determines whether the IAM policy name (`iam_policy_name`) is used as a prefix | `bool` | `true` | no |
| <a name="input_iam_role_description"></a> [iam\_role\_description](#input\_iam\_role\_description) | Description to use on IAM role created | `string` | `"Stream Security IAM Role"` | no |
| <a name="input_iam_role_name"></a> [iam\_role\_name](#input\_iam\_role\_name) | Name to use on IAM role created | `string` | `"streamsec-role"` | no |
| <a name="input_iam_role_path"></a> [iam\_role\_path](#input\_iam\_role\_path) | Cluster IAM role path | `string` | `null` | no |
| <a name="input_iam_role_tags"></a> [iam\_role\_tags](#input\_iam\_role\_tags) | A map of additional tags to add to the IAM role created | `map(string)` | `{}` | no |
| <a name="input_iam_role_use_name_prefix"></a> [iam\_role\_use\_name\_prefix](#input\_iam\_role\_use\_name\_prefix) | Determines whether the IAM role name (`iam_role_name`) is used as a prefix | `bool` | `true` | no |
| <a name="input_region"></a> [region](#input\_region) | The AWS region to deploy resources in. | `string` | n/a | yes |
| <a name="input_streamsec_account"></a> [streamsec\_account](#input\_streamsec\_account) | The AWS Account ID for the Stream.Security account. | `string` | `"624907860825"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | A map of global tags to add to all created resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_lambda_collection_token"></a> [lambda\_collection\_token](#output\_lambda\_collection\_token) | n/a |
<!-- END_TF_DOCS -->