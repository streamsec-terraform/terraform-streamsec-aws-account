# terraform-streamsec-aws-account/flow-logs
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

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_flow_log.streamsec_flowlogs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/flow_log) | resource |
| [aws_iam_policy.lambda_exec_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.lambda_execution_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.lambda_flowlogs_exec_policy_attachment](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.lambda_flowlogs_execution_role_policy_attachment](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_lambda_function.streamsec_flowlogs_lambda](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_function_event_invoke_config.streamsec_options_cloudwatch](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function_event_invoke_config) | resource |
| [aws_lambda_layer_version.streamsec_lambda_layer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_layer_version) | resource |
| [aws_lambda_permission.streamsec_flowlogs_allow_s3_invoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_s3_bucket.streamsec_flowlogs_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.flowlogs_bucket_config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_notification.flowlogs_s3_lambda_trigger](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_notification) | resource |
| [aws_secretsmanager_secret.streamsec_collection_secret](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.streamsec_collection_secret_version](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_s3_bucket.flowlogs_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/s3_bucket) | data source |
| [streamsec_host.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/host) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_collection_flowlogs_token_secret_name"></a> [collection\_flowlogs\_token\_secret\_name](#input\_collection\_flowlogs\_token\_secret\_name) | The name of the secret to use for the lambda function | `string` | `"streamsec-collection-token-flowlogs"` | no |
| <a name="input_create_flowlogs_bucket"></a> [create\_flowlogs\_bucket](#input\_create\_flowlogs\_bucket) | Whether to create an S3 bucket to store the flow logs | `bool` | `false` | no |
| <a name="input_flowlogs_bucket_force_destroy"></a> [flowlogs\_bucket\_force\_destroy](#input\_flowlogs\_bucket\_force\_destroy) | A boolean that indicates all objects should be deleted from the bucket so that the bucket can be destroyed without error | `bool` | `true` | no |
| <a name="input_flowlogs_bucket_lifecycle_rule"></a> [flowlogs\_bucket\_lifecycle\_rule](#input\_flowlogs\_bucket\_lifecycle\_rule) | n/a | <pre>list(object({<br>    id     = string<br>    prefix = string<br>    status = string<br>    days   = number<br>  }))</pre> | <pre>[<br>  {<br>    "days": 360,<br>    "id": "purge",<br>    "prefix": "AWSLogs/",<br>    "status": "Enabled"<br>  }<br>]</pre> | no |
| <a name="input_flowlogs_bucket_name"></a> [flowlogs\_bucket\_name](#input\_flowlogs\_bucket\_name) | The name of the S3 bucket to store the flow logs | `string` | `"streamsec-flowlogs"` | no |
| <a name="input_flowlogs_bucket_tags"></a> [flowlogs\_bucket\_tags](#input\_flowlogs\_bucket\_tags) | A map of additional tags to add to the S3 bucket created | `map(string)` | `{}` | no |
| <a name="input_flowlogs_bucket_use_name_prefix"></a> [flowlogs\_bucket\_use\_name\_prefix](#input\_flowlogs\_bucket\_use\_name\_prefix) | Whether to use a prefix for the bucket name | `bool` | `true` | no |
| <a name="input_lambda_batch_size"></a> [lambda\_batch\_size](#input\_lambda\_batch\_size) | n/a | `number` | `4000` | no |
| <a name="input_lambda_cloudwatch_max_event_age"></a> [lambda\_cloudwatch\_max\_event\_age](#input\_lambda\_cloudwatch\_max\_event\_age) | The maximum age of a request that Lambda sends to a function for processing, in seconds | `number` | `21600` | no |
| <a name="input_lambda_cloudwatch_max_retry"></a> [lambda\_cloudwatch\_max\_retry](#input\_lambda\_cloudwatch\_max\_retry) | The maximum number of times to retry when the function returns an error | `number` | `2` | no |
| <a name="input_lambda_cloudwatch_memory_size"></a> [lambda\_cloudwatch\_memory\_size](#input\_lambda\_cloudwatch\_memory\_size) | The amount of memory in MB to allocate to the lambda function | `number` | `128` | no |
| <a name="input_lambda_cloudwatch_s3_source_code_key"></a> [lambda\_cloudwatch\_s3\_source\_code\_key](#input\_lambda\_cloudwatch\_s3\_source\_code\_key) | The S3 key for the lambda source code | `string` | `"6c0c66c12749eb83543b83c0b2c27e69"` | no |
| <a name="input_lambda_cloudwatch_timeout"></a> [lambda\_cloudwatch\_timeout](#input\_lambda\_cloudwatch\_timeout) | The amount of time in seconds the lambda function is allowed to run | `number` | `60` | no |
| <a name="input_lambda_collection_token"></a> [lambda\_collection\_token](#input\_lambda\_collection\_token) | The collection token to use for the lambda function | `string` | n/a | yes |
| <a name="input_lambda_iam_role_description"></a> [lambda\_iam\_role\_description](#input\_lambda\_iam\_role\_description) | Description to use on IAM role created | `string` | `"Stream Security IAM Role"` | no |
| <a name="input_lambda_iam_role_name"></a> [lambda\_iam\_role\_name](#input\_lambda\_iam\_role\_name) | Name to use on IAM role created | `string` | `"streamsec-flowlogs-execution-role"` | no |
| <a name="input_lambda_iam_role_path"></a> [lambda\_iam\_role\_path](#input\_lambda\_iam\_role\_path) | Cluster IAM role path | `string` | `null` | no |
| <a name="input_lambda_iam_role_tags"></a> [lambda\_iam\_role\_tags](#input\_lambda\_iam\_role\_tags) | A map of additional tags to add to the IAM role created | `map(string)` | `{}` | no |
| <a name="input_lambda_iam_role_use_name_prefix"></a> [lambda\_iam\_role\_use\_name\_prefix](#input\_lambda\_iam\_role\_use\_name\_prefix) | Determines whether the IAM role name (`iam_role_name`) is used as a prefix | `bool` | `true` | no |
| <a name="input_lambda_layer_name"></a> [lambda\_layer\_name](#input\_lambda\_layer\_name) | The name of the lambda layer | `string` | `"streamsec-flowlogs-layer"` | no |
| <a name="input_lambda_layer_s3_source_code_key"></a> [lambda\_layer\_s3\_source\_code\_key](#input\_lambda\_layer\_s3\_source\_code\_key) | The S3 key for the lambda source code | `string` | `"24ad10212c195b9a805df9b82493877b"` | no |
| <a name="input_lambda_name"></a> [lambda\_name](#input\_lambda\_name) | Name of the lambda function | `string` | `"streamsec-flowlogs-lambda"` | no |
| <a name="input_lambda_policy_description"></a> [lambda\_policy\_description](#input\_lambda\_policy\_description) | Description to use on IAM policy created | `string` | `"Stream Security IAM Policy for flowlogs lambda"` | no |
| <a name="input_lambda_policy_name"></a> [lambda\_policy\_name](#input\_lambda\_policy\_name) | Name to use on IAM policy created | `string` | `"streamsec-flowlogs-policy"` | no |
| <a name="input_lambda_policy_path"></a> [lambda\_policy\_path](#input\_lambda\_policy\_path) | IAM policy path | `string` | `null` | no |
| <a name="input_lambda_policy_use_name_prefix"></a> [lambda\_policy\_use\_name\_prefix](#input\_lambda\_policy\_use\_name\_prefix) | Determines whether the IAM policy name (`iam_policy_name`) is used as a prefix | `bool` | `true` | no |
| <a name="input_lambda_security_group_ids"></a> [lambda\_security\_group\_ids](#input\_lambda\_security\_group\_ids) | The security group IDs to use for the lambda function | `list(string)` | `[]` | no |
| <a name="input_lambda_source_code_bucket_prefix"></a> [lambda\_source\_code\_bucket\_prefix](#input\_lambda\_source\_code\_bucket\_prefix) | The prefix to use for the lambda source code bucket | `string` | `"prod-lightlytics-artifacts"` | no |
| <a name="input_lambda_subnet_ids"></a> [lambda\_subnet\_ids](#input\_lambda\_subnet\_ids) | The subnet IDs to use for the lambda function | `list(string)` | `[]` | no |
| <a name="input_lambda_tags"></a> [lambda\_tags](#input\_lambda\_tags) | A map of additional tags to add to the lambda function created | `map(string)` | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | A map of global tags to add to all created resources | `map(string)` | `{}` | no |
| <a name="input_vpc_ids"></a> [vpc\_ids](#input\_vpc\_ids) | The VPC IDs to use for the flow logs | `list(string)` | `[]` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->