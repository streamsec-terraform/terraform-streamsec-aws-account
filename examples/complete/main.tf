provider "aws" {
  region = "us-east-1"
  alias  = "aws-east-1"
}

provider "aws" {
  region = "us-east-2"
  alias  = "aws-east-2"
}

provider "streamsec" {
  host         = "xxxxx.streamsec.io"
  username     = "xxxxx@example.com"
  password     = "xxxxxxxxxxxx"
  workspace_id = "xxxxxxxxxxxx"
}


module "account" {
  source                   = "../../"
  aws_account_display_name = "asfsdafds"
  aws_account_regions      = ["us-east-1", "us-west-2"]
}

module "real_time_us_east_1" {
  source = "../../modules/real-time-events"
  providers = {
    aws = aws.aws-east-1
  }
  depends_on = [module.account]

  # Optional: Centralized CloudWatch Logs collection
  # central_cloudtrail_log_groups    = ["aws-cloudtrail-logs-123456789012"]
  # central_vpc_flow_logs_log_groups = ["/aws/vpc/flowlogs/my-vpc"]
  # central_vpc_flow_logs_fields     = "version account-id action bytes dstaddr end interface-id log-status packets pkt-dstaddr pkt-srcaddr protocol srcaddr srcport dstport start vpc-id subnet-id instance-id tcp-flags region"
  # central_eks_audit_log_groups     = ["/aws/eks/my-cluster/cluster"]
  # central_route53_log_groups       = ["/staging/route53dnslogs/cw-test"]
  # central_bedrock_log_groups       = ["/staging/awsbedrocklogs/cw-test"]
  # central_kinesis_stream_arns      = ["arn:aws:kinesis:us-east-1:123456789012:stream/my-stream"]

  # API Gateway access logs via CloudWatch Logs (or via the Kinesis stream above).
  # central_apigateway_log_format is REQUIRED whenever central_apigateway_log_groups is set —
  # it must match the access-log format configured on the API stage, or the logs are skipped.
  # central_apigateway_log_groups    = ["/aws/apigateway/my-api/access-logs"]
  # Include $context.apiId so the platform can attribute logs to the API resource (without it they show as "unknown"). domainName/stage recommended too.
  # central_apigateway_log_format    = "{\"apiId\":\"$context.apiId\",\"domainName\":\"$context.domainName\",\"stage\":\"$context.stage\",\"requestId\":\"$context.requestId\",\"ip\":\"$context.identity.sourceIp\",\"httpMethod\":\"$context.httpMethod\",\"path\":\"$context.path\",\"status\":\"$context.status\"}"
}

module "real_time_us_east_2" {
  source = "../../modules/real-time-events"
  providers = {
    aws = aws.aws-east-2
  }
  depends_on = [module.account]
}

module "flow_logs" {
  source                 = "../../modules/flow-logs"
  create_flowlogs_bucket = true                  # whether to create a bucket for flow logs and attach it to the VPCs
  vpc_ids                = ["vpc-xxxxxxxxxxxxx"] # required if create_flowlogs_bucket is true
  depends_on             = [module.account]
}

module "iam_activity" {
  source                   = "../../modules/iam-activity"
  iam_activity_bucket_name = "xxxxxxxxxxxxx"

  # Optional: collect API Gateway access logs from an existing bucket (must be in the same region; e.g. fed via Firehose).
  # PREREQUISITE: EventBridge notifications must be enabled on the bucket (Properties -> Amazon EventBridge).
  # apigateway_bucket_name   = "my-apigateway-access-logs"
  # apigateway_log_format    = "{\"apiId\":\"$context.apiId\",\"domainName\":\"$context.domainName\",\"stage\":\"$context.stage\",\"requestId\":\"$context.requestId\",\"ip\":\"$context.identity.sourceIp\",\"httpMethod\":\"$context.httpMethod\",\"path\":\"$context.path\",\"status\":\"$context.status\"}" # must match the format set on the API stage (required); include $context.apiId for resource attribution
  # apigateway_s3_key_prefix = "apigw/"   # only match/read objects under this prefix
  # apigateway_kms_key_arn   = "arn:aws:kms:us-east-1:123456789012:key/xxxx" # if the bucket uses SSE-KMS

  # Optional: collect S3 server access logs from an existing target bucket (same prerequisites as above)
  # s3_access_logs_bucket_name = "my-s3-access-logs"
  # s3_access_logs_key_prefix  = "access-logs/"

  # Optional: collect ALB access logs from an existing target bucket (same prerequisites as above)
  # alb_access_logs_bucket_name = "my-alb-access-logs"
  # alb_access_logs_key_prefix  = "AWSLogs/"

  depends_on = [module.account]
}

module "cost" {
  source             = "../../modules/cost"
  create_cost_bucket = true
  depends_on         = [module.account]
}

module "response" {
  source     = "../../modules/response"
  depends_on = [module.account]
}

module "eks_audit_us_east_1" {
  source = "../../modules/eks-audit"
  providers = {
    aws = aws.aws-east-1
  }
  depends_on = [module.account]
}

module "eks_audit_us_east_2" {
  source               = "../../modules/eks-audit"
  resource_prefix      = "acme"
  eks_exclude_clusters = ["test-cluster"]
  providers = {
    aws = aws.aws-east-2
  }
  depends_on = [module.account]
}
