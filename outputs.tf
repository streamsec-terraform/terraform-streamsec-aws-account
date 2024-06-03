output "lambda_collection_token" {
  value     = streamsec_aws_account.this.streamsec_collection_token
  sensitive = true
}