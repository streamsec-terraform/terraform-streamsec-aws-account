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
  # Optional: if the bucket uses SSE-KMS (e.g. the CMK of a CloudTrail organization trail),
  # grant the collector Lambda kms:Decrypt on the key.
  # iam_activity_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/xxxx"

  # Optional: shared / org-trail bucket whose notification configuration is owned
  # outside this module (e.g. it already carries another vendor's SNS topic).
  # The module then never writes the bucket notification (a replace-all document).
  # With the eventbridge trigger it still creates its own rule; EventBridge must
  # already be enabled on the bucket. Without it, the module creates NO trigger:
  # drive the collector yourself with an EventBridge rule whose target is the
  # lambda_function_arn output PLUS an aws_lambda_permission for
  # events.amazonaws.com scoped to your rule's ARN (function_name =
  # lambda_function_name) — without the permission, invocations fail silently.
  # iam_activity_s3_eventbridge_trigger     = true
  # iam_activity_manage_bucket_notification = false

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

# Agentless vulnerability scanning — one module instance per region you want
# scanned. customer_id is the same value as the provider's workspace_id above.
#
# Delete the console's CloudFormation scanner stack for a region before applying
# here. The module refuses to apply while one is present: ecs:CreateCluster is an
# upsert, so two scanners in a region end up deleting each other's snapshots.
#
# Default networking: a dedicated VPC with a NAT gateway (~$32/mo per region) so
# the Fargate task runs with no public IP, plus interface and gateway VPC
# endpoints so snapshot block reads bypass the NAT — measured at a ~96% cut in
# NAT traffic, which is most of the scanner's running cost.
module "volume_scanner_us_east_1" {
  source      = "../../modules/volume-scanner"
  customer_id = "xxxxxxxxxxxx"

  # Encrypted volumes are scanned by default. Customer-managed CMKs need the
  # KMS grants this turns on; without them those instances report no findings.
  # scan_encrypted_volumes = true

  providers = {
    aws = aws.aws-east-1
  }
  depends_on = [module.account]
}

# Bring your own private subnets instead, to avoid a second NAT gateway. Each
# needs a 0.0.0.0/0 route to a NAT gateway, NAT instance, appliance ENI, Gateway
# Load Balancer endpoint, Transit Gateway, virtual private gateway, Cloud WAN
# core network or Outposts local gateway. An S3/DynamoDB gateway endpoint is NOT
# egress and is rejected.
#
# Checked at plan time when Terraform can read the module's data sources. The
# depends_on below defers them whenever module.account has pending changes — a
# first apply, for instance — and the checks then run at apply instead.
#
# No VPC endpoints are created in this mode, since the module does not own the
# VPC. Add an interface endpoint for the EBS Direct API to your own VPC to get
# the same saving.
module "volume_scanner_us_east_2" {
  source             = "../../modules/volume-scanner"
  customer_id        = "xxxxxxxxxxxx"
  create_scanner_vpc = false
  vpc_id             = "vpc-xxxxxxxxxxxxx"
  subnet_ids         = ["subnet-xxxxxxxxxxxxx"]

  # Optional scanners — all off by default except language packages.
  # scan_secrets      = true
  # scan_ai_workloads = true
  # scan_databases    = true

  providers = {
    aws = aws.aws-east-2
  }
  depends_on = [module.account]
}
