###############################################################################
# A volume scanner hub and one spoke
#
# The hub account runs the scanner (modules/volume-scanner) and also scans the
# spoke account, through the role modules/volume-scanner-access creates there.
# Both accounts must already be integrated with Stream Security, by the root
# module or the console.
###############################################################################

# The hub account, in the region to scan: the scanner is regional.
provider "aws" {
  alias  = "hub"
  region = "us-east-1"
}

# The spoke account. IAM is global, so the region only picks the API endpoint.
provider "aws" {
  alias  = "spoke"
  region = "us-east-1"

  assume_role {
    role_arn = var.spoke_admin_role_arn
  }
}

# Reads STREAMSEC_HOST, STREAMSEC_WORKSPACE_ID and STREAMSEC_API_TOKEN from the
# environment.
provider "streamsec" {}

data "aws_caller_identity" "hub" {
  provider = aws.hub
}

data "aws_caller_identity" "spoke" {
  provider = aws.spoke
}

data "streamsec_aws_account" "hub" {
  cloud_account_id = data.aws_caller_identity.hub.account_id
}

data "streamsec_aws_account" "spoke" {
  cloud_account_id = data.aws_caller_identity.spoke.account_id
}

# The hub's scanner. Its acknowledgement tells Stream it can scan other accounts.
module "hub_scanner" {
  source      = "../../modules/volume-scanner"
  customer_id = var.workspace_id

  providers = {
    aws = aws.hub
  }
}

# Which accounts the hub scans: here the spoke. coverage = "all" instead scans
# every other integrated AWS account that has no scanner of its own in the region
# and no other hub; leave out account_ids then. Only one hub may cover "all", and
# each account still needs the access role.
resource "streamsec_aws_scanner_hub" "this" {
  account_id  = data.streamsec_aws_account.hub.id
  coverage    = "selected"
  account_ids = [data.streamsec_aws_account.spoke.id]

  depends_on = [module.hub_scanner]
}

# The role the hub's scanner assumes in the spoke. Stream gives the hub its
# external id when it becomes a hub, so this waits for that.
module "spoke_access" {
  source         = "../../modules/volume-scanner-access"
  hub_account_id = streamsec_aws_scanner_hub.this.account_id

  providers = {
    aws = aws.spoke
  }

  depends_on = [streamsec_aws_scanner_hub.this]
}
