# terraform-streamsec-aws-account/real-time-events
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 3.0 |
| <a name="requirement_streamsec"></a> [streamsec](#requirement\_streamsec) | >= 1.7 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 3.0 |
| <a name="provider_streamsec"></a> [streamsec](#provider\_streamsec) | >= 1.7 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_cloudwatch_event_rule.streamsec_cloudwatch_rules](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.streamsec_lambda_cloudwatch_target](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_iam_policy.lambda_exec_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.lambda_execution_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.lambda_basic_execution_role_policy_attachment](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.lambda_exec_policy_attachment](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_lambda_function.streamsec_real_time_events_lambda](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_function_event_invoke_config.streamsec_options_cloudwatch](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function_event_invoke_config) | resource |
| [aws_lambda_layer_version.streamsec_lambda_layer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_layer_version) | resource |
| [aws_lambda_permission.streamsec_allow_lambda_cloudwatch_invocation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_secretsmanager_secret.streamsec_collection_secret](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.streamsec_collection_secret_version](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [streamsec_aws_real_time_events_ack.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/resources/aws_real_time_events_ack) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [streamsec_aws_account.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/aws_account) | data source |
| [streamsec_host.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/host) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_lambda_cloudwatch_max_event_age"></a> [lambda\_cloudwatch\_max\_event\_age](#input\_lambda\_cloudwatch\_max\_event\_age) | The maximum age of a request that Lambda sends to a function for processing, in seconds | `number` | `21600` | no |
| <a name="input_lambda_cloudwatch_max_retry"></a> [lambda\_cloudwatch\_max\_retry](#input\_lambda\_cloudwatch\_max\_retry) | The maximum number of times to retry when the function returns an error | `number` | `2` | no |
| <a name="input_lambda_cloudwatch_memory_size"></a> [lambda\_cloudwatch\_memory\_size](#input\_lambda\_cloudwatch\_memory\_size) | The amount of memory in MB to allocate to the lambda function | `number` | `128` | no |
| <a name="input_lambda_cloudwatch_s3_source_code_key"></a> [lambda\_cloudwatch\_s3\_source\_code\_key](#input\_lambda\_cloudwatch\_s3\_source\_code\_key) | The S3 key for the lambda source code | `string` | `"6c0c66c12749eb83543b83c0b2c27e69"` | no |
| <a name="input_lambda_cloudwatch_timeout"></a> [lambda\_cloudwatch\_timeout](#input\_lambda\_cloudwatch\_timeout) | The amount of time in seconds the lambda function is allowed to run | `number` | `60` | no |
| <a name="input_lambda_collection_secret_name"></a> [lambda\_collection\_secret\_name](#input\_lambda\_collection\_secret\_name) | The name of the secret to use for the lambda function | `string` | `"streamsec-collection-token"` | no |
| <a name="input_lambda_iam_role_description"></a> [lambda\_iam\_role\_description](#input\_lambda\_iam\_role\_description) | Description to use on IAM role created | `string` | `"Stream Security IAM Role"` | no |
| <a name="input_lambda_iam_role_name"></a> [lambda\_iam\_role\_name](#input\_lambda\_iam\_role\_name) | Name to use on IAM role created | `string` | `"streamsec-events-lambda-execution-role"` | no |
| <a name="input_lambda_iam_role_path"></a> [lambda\_iam\_role\_path](#input\_lambda\_iam\_role\_path) | Cluster IAM role path | `string` | `null` | no |
| <a name="input_lambda_iam_role_tags"></a> [lambda\_iam\_role\_tags](#input\_lambda\_iam\_role\_tags) | A map of additional tags to add to the IAM role created | `map(string)` | `{}` | no |
| <a name="input_lambda_iam_role_use_name_prefix"></a> [lambda\_iam\_role\_use\_name\_prefix](#input\_lambda\_iam\_role\_use\_name\_prefix) | Determines whether the IAM role name (`iam_role_name`) is used as a prefix | `bool` | `true` | no |
| <a name="input_lambda_layer_name"></a> [lambda\_layer\_name](#input\_lambda\_layer\_name) | The name of the lambda layer | `string` | `"streamsec-real-time-events-layer"` | no |
| <a name="input_lambda_layer_s3_source_code_key"></a> [lambda\_layer\_s3\_source\_code\_key](#input\_lambda\_layer\_s3\_source\_code\_key) | The S3 key for the lambda source code | `string` | `"24ad10212c195b9a805df9b82493877b"` | no |
| <a name="input_lambda_name"></a> [lambda\_name](#input\_lambda\_name) | Name of the lambda function | `string` | `"streamsec-real-time-events-lambda"` | no |
| <a name="input_lambda_policy_description"></a> [lambda\_policy\_description](#input\_lambda\_policy\_description) | Description to use on IAM policy created | `string` | `"Stream Security IAM Policy for real time events lambda"` | no |
| <a name="input_lambda_policy_name"></a> [lambda\_policy\_name](#input\_lambda\_policy\_name) | Name to use on IAM policy created | `string` | `"streamsec-events-lambda-policy"` | no |
| <a name="input_lambda_policy_path"></a> [lambda\_policy\_path](#input\_lambda\_policy\_path) | IAM policy path | `string` | `null` | no |
| <a name="input_lambda_policy_use_name_prefix"></a> [lambda\_policy\_use\_name\_prefix](#input\_lambda\_policy\_use\_name\_prefix) | Determines whether the IAM policy name (`iam_policy_name`) is used as a prefix | `bool` | `true` | no |
| <a name="input_lambda_security_group_ids"></a> [lambda\_security\_group\_ids](#input\_lambda\_security\_group\_ids) | The security group IDs to use for the lambda function | `list(string)` | `[]` | no |
| <a name="input_lambda_source_code_bucket_prefix"></a> [lambda\_source\_code\_bucket\_prefix](#input\_lambda\_source\_code\_bucket\_prefix) | The prefix to use for the lambda source code bucket | `string` | `"prod-lightlytics-artifacts"` | no |
| <a name="input_lambda_subnet_ids"></a> [lambda\_subnet\_ids](#input\_lambda\_subnet\_ids) | The subnet IDs to use for the lambda function | `list(string)` | `[]` | no |
| <a name="input_lambda_tags"></a> [lambda\_tags](#input\_lambda\_tags) | A map of additional tags to add to the lambda function created | `map(string)` | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | A map of global tags to add to all created resources | `map(string)` | `{}` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->