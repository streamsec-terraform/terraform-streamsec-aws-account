provider "aws" {
  region = "us-east-1"
  alias = "aws-east-1"
}

provider "aws" {
  region = "us-east-2"
  alias = "aws-east-2"
}

provider "streamsec" {
  host         = "xxxxx.streamsec.io"
  username     = "xxxxx@example.com"
  password     = "xxxxxxxxxxxx"
  workspace_id = "xxxxxxxxxxxx"
}


module "account" {
  source            = "../../"
  aws_account_display_name = "asfsdafds"
  aws_account_regions      = ["us-east-1", "us-west-2"]
}

module "real_time_us_east_1" {
  source                  = "../../modules/real-time-events"
  providers = {
    aws = aws.aws-east-1
  }
}

module "real_time_us_east_2" {
  source                  = "../../modules/real-time-events"
  providers = {
    aws = aws.aws-east-2
  }
}

module "flow_logs" {
  source                  = "../../modules/flow-logs"
  create_flowlogs_bucket  = true # whether to create a bucket for flow logs and attach it to the VPCs
  vpc_ids                 = ["vpc-xxxxxxxxxxxxx"] # required if create_flowlogs_bucket is true
}

module "iam_activity" {
  source                   = "../../modules/iam-activity"
  iam_activity_bucket_name = "xxxxxxxxxxxxx"
}

module "cost" {
  source                  = "../../modules/cost"
  create_cost_bucket      = true
}
