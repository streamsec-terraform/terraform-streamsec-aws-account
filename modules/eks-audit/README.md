# terraform-streamsec-aws-account/eks-audit

Terraform module for collecting EKS audit logs and forwarding them to Stream Security.

This module auto-discovers EKS clusters in the region, creates CloudWatch Log subscription filters on their audit log groups, and deploys a collector Lambda that forwards the logs to the Stream Security API.

## Usage

```hcl
# Basic — auto-discover all clusters in the region
module "eks_audit" {
  source     = "streamsec-terraform/aws-account//modules/eks-audit"
  depends_on = [module.account]
}

# With include/exclude filtering and prefix
module "eks_audit" {
  source               = "streamsec-terraform/aws-account//modules/eks-audit"
  resource_prefix      = "acme"
  eks_include_clusters = ["prod-cluster", "staging-cluster"]
  depends_on           = [module.account]
}

# Multi-region with shared IAM role
module "eks_audit_us_east_1" {
  source = "streamsec-terraform/aws-account//modules/eks-audit"
  providers = {
    aws = aws.us-east-1
  }
  depends_on = [module.account]
}

module "eks_audit_us_west_2" {
  source             = "streamsec-terraform/aws-account//modules/eks-audit"
  collector_role_arn = module.eks_audit_us_east_1.collector_role_arn
  providers = {
    aws = aws.us-west-2
  }
  depends_on = [module.account]
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_archive"></a> [archive](#requirement\_archive) | >= 2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.0 |
| <a name="requirement_streamsec"></a> [streamsec](#requirement\_streamsec) | >= 1.7 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_archive"></a> [archive](#provider\_archive) | >= 2.0 |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 6.0 |
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.0 |
| <a name="provider_streamsec"></a> [streamsec](#provider\_streamsec) | >= 1.7 |

## Resources

| Name | Type |
|------|------|
| [aws_cloudwatch_log_group.collector](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_subscription_filter.eks_audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_subscription_filter) | resource |
| [aws_iam_role.collector](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.secrets_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.lambda_basic_execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_lambda_function.collector](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_permission.allow_cloudwatch_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_secretsmanager_secret.collection_token](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.collection_token](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [random_string.suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_eks_clusters.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/eks_clusters) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [streamsec_aws_account.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/aws_account) | data source |
| [streamsec_host.this](https://registry.terraform.io/providers/streamsec-terraform/streamsec/latest/docs/data-sources/host) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_collection_token_secret_name"></a> [collection\_token\_secret\_name](#input\_collection\_token\_secret\_name) | Base name for the Secrets Manager secret storing the collection token | `string` | `"streamsec-eks-collection-token"` | no |
| <a name="input_collector_lambda_memory_size"></a> [collector\_lambda\_memory\_size](#input\_collector\_lambda\_memory\_size) | The amount of memory in MB to allocate to the collector Lambda function | `number` | `128` | no |
| <a name="input_collector_lambda_timeout"></a> [collector\_lambda\_timeout](#input\_collector\_lambda\_timeout) | The amount of time in seconds the collector Lambda function is allowed to run | `number` | `30` | no |
| <a name="input_collector_role_arn"></a> [collector\_role\_arn](#input\_collector\_role\_arn) | If set, skip IAM role creation and use this existing role ARN for the collector Lambda | `string` | `null` | no |
| <a name="input_eks_exclude_clusters"></a> [eks\_exclude\_clusters](#input\_eks\_exclude\_clusters) | Skip these EKS clusters from subscription | `list(string)` | `[]` | no |
| <a name="input_eks_include_clusters"></a> [eks\_include\_clusters](#input\_eks\_include\_clusters) | Only subscribe these EKS clusters. If empty, all clusters in the region are included. | `list(string)` | `[]` | no |
| <a name="input_lambda_log_retention_days"></a> [lambda\_log\_retention\_days](#input\_lambda\_log\_retention\_days) | The number of days to retain the collector Lambda CloudWatch logs | `number` | `7` | no |
| <a name="input_resource_prefix"></a> [resource\_prefix](#input\_resource\_prefix) | Optional prefix prepended before StreamSecurity in all resource names | `string` | `""` | no |
| <a name="input_secret_recovery_window_days"></a> [secret\_recovery\_window\_days](#input\_secret\_recovery\_window\_days) | Number of days Secrets Manager waits before deleting the secret. Set to 0 for immediate deletion. | `number` | `0` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | A map of global tags to add to all created resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_collector_lambda_arn"></a> [collector\_lambda\_arn](#output\_collector\_lambda\_arn) | ARN of the EKS audit collector Lambda function |
| <a name="output_collector_lambda_name"></a> [collector\_lambda\_name](#output\_collector\_lambda\_name) | Name of the EKS audit collector Lambda function |
| <a name="output_collector_role_arn"></a> [collector\_role\_arn](#output\_collector\_role\_arn) | ARN of the IAM role used by the collector Lambda |
| <a name="output_secret_arn"></a> [secret\_arn](#output\_secret\_arn) | ARN of the Secrets Manager secret storing the collection token |
| <a name="output_subscribed_clusters"></a> [subscribed\_clusters](#output\_subscribed\_clusters) | List of EKS cluster names that have subscription filters |
<!-- END_TF_DOCS -->
