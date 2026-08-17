terraform {
  required_providers {
    aws       = { source = "hashicorp/aws", version = "~> 6.0" }
    streamsec = { source = "streamsec-terraform/streamsec", version = ">= 1.7" }
  }
}

# count = 2 → LENGTH is known at plan, ids are NOT. This is the documented
# supported case: README says validation works as long as the length is known.
resource "aws_vpc" "t" { cidr_block = "10.60.0.0/16" }

resource "aws_subnet" "private" {
  count      = 2
  vpc_id     = aws_vpc.t.id
  cidr_block = cidrsubnet("10.60.0.0/16", 8, count.index)
}

module "scanner" {
  source      = "../.."
  customer_id = "customer-abc"

  create_scanner_vpc = false
  vpc_id             = aws_vpc.t.id
  subnet_ids         = aws_subnet.private[*].id
  # validate_subnet_egress left at its default true
}
