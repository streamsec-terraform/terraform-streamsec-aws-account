# terraform-streamsec-aws-account/flow-logs
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 3.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.6 |
| <a name="requirement_streamsec"></a> [streamsec](#requirement\_streamsec) | >= 1.7 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 3.0 |
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.6 |
| <a name="provider_streamsec"></a> [streamsec](#provider\_streamsec) | >= 1.7 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_cloudwatch_log_group.streamsec_lambda_log_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cur_report_definition.cur_report_definition](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cur_report_definition) | resource |
| [aws_iam_policy.lambda_exec_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.streamsec_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.lambda_execution_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.lambda_cost_exec_policy_attachment](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.lambda_cost_execution_role_policy_attachment](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.streamsec_policy_attachment](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_lambda_function.streamsec_cost_lambda](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_function_event_invoke_config.streamsec_options_cloudwatch](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function_event_invoke_config) | resource |
| [aws_lambda_permission.streamsec_cost_allow_s3_invoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_s3_bucket.streamsec_cost_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.cost_bucket_config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_notification.cost_s3_lambda_trigger](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_notification) | resource |
| [aws_s3_bucket_policy.s3_cloudtrail_policy_attachment](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_secretsmanager_secret.streamsec_collection_secret](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.streamsec_collection_secret_version](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [random_uuid.external_id](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/uuid) | resource |
| [streamsec_aws_cost_ack.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/resources/aws_cost_ack) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_s3_bucket.cost_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/s3_bucket) | data source |
| [streamsec_aws_account.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/aws_account) | data source |
| [streamsec_host.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/host) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_collection_cost_token_secret_name"></a> [collection\_cost\_token\_secret\_name](#input\_collection\_cost\_token\_secret\_name) | The name of the secret to use for the lambda function | `string` | `"streamsec-collection-token-cost"` | no |
| <a name="input_cost_bucket_force_destroy"></a> [cost\_bucket\_force\_destroy](#input\_cost\_bucket\_force\_destroy) | A boolean that indicates all objects should be deleted from the bucket so that the bucket can be destroyed without error | `bool` | `true` | no |
| <a name="input_cost_bucket_lifecycle_rule"></a> [cost\_bucket\_lifecycle\_rule](#input\_cost\_bucket\_lifecycle\_rule) | A list of lifecycle rules to apply to the S3 bucket | <pre>list(object({<br>    id     = string<br>    prefix = string<br>    status = string<br>    days   = number<br>  }))</pre> | <pre>[<br>  {<br>    "days": 360,<br>    "id": "purge",<br>    "prefix": "AWSLogs/",<br>    "status": "Enabled"<br>  }<br>]</pre> | no |
| <a name="input_cost_bucket_name"></a> [cost\_bucket\_name](#input\_cost\_bucket\_name) | The name of the S3 bucket to store the flow logs | `string` | `"streamsec-cost"` | no |
| <a name="input_cost_bucket_tags"></a> [cost\_bucket\_tags](#input\_cost\_bucket\_tags) | A map of additional tags to add to the S3 bucket created | `map(string)` | `{}` | no |
| <a name="input_cost_bucket_use_name_prefix"></a> [cost\_bucket\_use\_name\_prefix](#input\_cost\_bucket\_use\_name\_prefix) | Whether to use a prefix for the bucket name | `bool` | `true` | no |
| <a name="input_create_cost_bucket"></a> [create\_cost\_bucket](#input\_create\_cost\_bucket) | Whether to create an S3 bucket to store the flow logs | `bool` | `false` | no |
| <a name="input_cur_prefix"></a> [cur\_prefix](#input\_cur\_prefix) | The prefix to use for the CUR report | `string` | `"/streamsec-cost-report"` | no |
| <a name="input_cur_report_name"></a> [cur\_report\_name](#input\_cur\_report\_name) | Whether to create a CUR report | `string` | `"streamsec-cost-report"` | no |
| <a name="input_cur_time_unit"></a> [cur\_time\_unit](#input\_cur\_time\_unit) | The time unit for the CUR report | `string` | `"DAILY"` | no |
| <a name="input_iam_policy_description"></a> [iam\_policy\_description](#input\_iam\_policy\_description) | Description to use on IAM policy created | `string` | `"Stream Security IAM Policy"` | no |
| <a name="input_iam_policy_name"></a> [iam\_policy\_name](#input\_iam\_policy\_name) | Name to use on IAM policy created | `string` | `"streamsec-policy"` | no |
| <a name="input_iam_policy_path"></a> [iam\_policy\_path](#input\_iam\_policy\_path) | IAM policy path | `string` | `null` | no |
| <a name="input_iam_policy_tags"></a> [iam\_policy\_tags](#input\_iam\_policy\_tags) | A map of additional tags to add to the IAM policy created | `map(string)` | `{}` | no |
| <a name="input_iam_policy_use_name_prefix"></a> [iam\_policy\_use\_name\_prefix](#input\_iam\_policy\_use\_name\_prefix) | Determines whether the IAM policy name (`iam_policy_name`) is used as a prefix | `bool` | `true` | no |
| <a name="input_iam_role_description"></a> [iam\_role\_description](#input\_iam\_role\_description) | Description to use on IAM role created | `string` | `"Stream Security IAM Role"` | no |
| <a name="input_iam_role_name"></a> [iam\_role\_name](#input\_iam\_role\_name) | Name to use on IAM role created | `string` | `"streamsec-cost-role"` | no |
| <a name="input_iam_role_path"></a> [iam\_role\_path](#input\_iam\_role\_path) | Cluster IAM role path | `string` | `null` | no |
| <a name="input_iam_role_tags"></a> [iam\_role\_tags](#input\_iam\_role\_tags) | A map of additional tags to add to the IAM role created | `map(string)` | `{}` | no |
| <a name="input_iam_role_use_name_prefix"></a> [iam\_role\_use\_name\_prefix](#input\_iam\_role\_use\_name\_prefix) | Determines whether the IAM role name (`iam_role_name`) is used as a prefix | `bool` | `true` | no |
| <a name="input_lambda_cloudwatch_max_event_age"></a> [lambda\_cloudwatch\_max\_event\_age](#input\_lambda\_cloudwatch\_max\_event\_age) | The maximum age of a request that Lambda sends to a function for processing, in seconds | `number` | `21600` | no |
| <a name="input_lambda_cloudwatch_max_retry"></a> [lambda\_cloudwatch\_max\_retry](#input\_lambda\_cloudwatch\_max\_retry) | The maximum number of times to retry when the function returns an error | `number` | `2` | no |
| <a name="input_lambda_cloudwatch_memory_size"></a> [lambda\_cloudwatch\_memory\_size](#input\_lambda\_cloudwatch\_memory\_size) | The amount of memory in MB to allocate to the lambda function | `number` | `128` | no |
| <a name="input_lambda_cloudwatch_s3_source_code_key"></a> [lambda\_cloudwatch\_s3\_source\_code\_key](#input\_lambda\_cloudwatch\_s3\_source\_code\_key) | The S3 key for the lambda source code | `string` | `"fccdf51e8501d87a570ba11a49eaf12c"` | no |
| <a name="input_lambda_cloudwatch_timeout"></a> [lambda\_cloudwatch\_timeout](#input\_lambda\_cloudwatch\_timeout) | The amount of time in seconds the lambda function is allowed to run | `number` | `60` | no |
| <a name="input_lambda_iam_role_description"></a> [lambda\_iam\_role\_description](#input\_lambda\_iam\_role\_description) | Description to use on IAM role created | `string` | `"Stream Security IAM Role"` | no |
| <a name="input_lambda_iam_role_name"></a> [lambda\_iam\_role\_name](#input\_lambda\_iam\_role\_name) | Name to use on IAM role created | `string` | `"streamsec-cost-execution-role"` | no |
| <a name="input_lambda_iam_role_path"></a> [lambda\_iam\_role\_path](#input\_lambda\_iam\_role\_path) | Cluster IAM role path | `string` | `null` | no |
| <a name="input_lambda_iam_role_tags"></a> [lambda\_iam\_role\_tags](#input\_lambda\_iam\_role\_tags) | A map of additional tags to add to the IAM role created | `map(string)` | `{}` | no |
| <a name="input_lambda_iam_role_use_name_prefix"></a> [lambda\_iam\_role\_use\_name\_prefix](#input\_lambda\_iam\_role\_use\_name\_prefix) | Determines whether the IAM role name (`iam_role_name`) is used as a prefix | `bool` | `true` | no |
| <a name="input_lambda_log_group_retention"></a> [lambda\_log\_group\_retention](#input\_lambda\_log\_group\_retention) | The number of days to retain log events in the log group | `number` | `30` | no |
| <a name="input_lambda_name"></a> [lambda\_name](#input\_lambda\_name) | Name of the lambda function | `string` | `"streamsec-cost-lambda"` | no |
| <a name="input_lambda_policy_description"></a> [lambda\_policy\_description](#input\_lambda\_policy\_description) | Description to use on IAM policy created | `string` | `"Stream Security IAM Policy for cost lambda"` | no |
| <a name="input_lambda_policy_name"></a> [lambda\_policy\_name](#input\_lambda\_policy\_name) | Name to use on IAM policy created | `string` | `"streamsec-cost-policy"` | no |
| <a name="input_lambda_policy_path"></a> [lambda\_policy\_path](#input\_lambda\_policy\_path) | IAM policy path | `string` | `null` | no |
| <a name="input_lambda_policy_use_name_prefix"></a> [lambda\_policy\_use\_name\_prefix](#input\_lambda\_policy\_use\_name\_prefix) | Determines whether the IAM policy name (`iam_policy_name`) is used as a prefix | `bool` | `true` | no |
| <a name="input_lambda_security_group_ids"></a> [lambda\_security\_group\_ids](#input\_lambda\_security\_group\_ids) | The security group IDs to use for the lambda function | `list(string)` | `[]` | no |
| <a name="input_lambda_source_code_bucket_prefix"></a> [lambda\_source\_code\_bucket\_prefix](#input\_lambda\_source\_code\_bucket\_prefix) | The prefix to use for the lambda source code bucket | `string` | `"prod-lightlytics-artifacts"` | no |
| <a name="input_lambda_subnet_ids"></a> [lambda\_subnet\_ids](#input\_lambda\_subnet\_ids) | The subnet IDs to use for the lambda function | `list(string)` | `[]` | no |
| <a name="input_streamsec_account"></a> [streamsec\_account](#input\_streamsec\_account) | The AWS Account ID for the Stream.Security account. | `string` | `"624907860825"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | A map of global tags to add to all created resources | `map(string)` | `{}` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->
