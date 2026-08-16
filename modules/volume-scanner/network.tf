################################################################################
# Dedicated scanner VPC (create_scanner_vpc = true, the default)
#
# The VPC is split into two equal subnets in a single availability zone:
#   - public  — holds the NAT Gateway only; no Fargate task ever runs here.
#               map_public_ip_on_launch is off: the NAT Gateway takes its public
#               address from the Elastic IP below, not from subnet auto-assign,
#               and nothing else is ever launched into this subnet.
#   - private — where Fargate runs. No public IP; egress via the NAT.
#
# Single AZ, deliberately. A second private subnet in another AZ would give
# ECS more placement options, but it would NOT buy AZ fault tolerance: the one
# NAT gateway lives in a single AZ, so losing that AZ takes egress out either
# way. Real resilience needs a NAT per AZ, which doubles the standing cost for
# a workload that runs once a day and retries. Documented rather than
# half-solved; supply your own multi-AZ subnets if you need it.
#
# The scanner accepts no inbound traffic. A NAT Gateway costs ~$32/mo idle plus
# ~$0.045/GB processed — the cost of running the task with no public IP, which
# SOC 2, CIS AWS Foundations and PCI-DSS baselines require of compute workloads.
################################################################################

data "aws_availability_zones" "available" {
  count = var.create_scanner_vpc ? 1 : 0
  state = "available"

  # Exclude Local Zones and Wavelength zones. They are returned alongside real
  # AZs once opted into, and `names` is sorted lexicographically — so
  # "us-west-2-lax-1a" sorts BEFORE "us-west-2a" ('-' is 0x2d, 'a' is 0x61) and
  # would win names[0]. Fargate is not offered in Local Zones, so the scanner
  # would provision cleanly and then fail every RunTask with
  # InvalidParameterException, producing no results at all.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# The coexistence precondition sits on the VPC as well as the ECS cluster. With
# the documented `depends_on = [module.account]` wiring Terraform defers this
# module's data sources to apply, so the guard cannot always run at plan time —
# and the VPC has no dependency on the cluster, so without its own check it would
# be created in parallel and left behind, along with the NAT gateway (~$32/mo)
# and Elastic IP downstream of it, when the cluster's check trips.
resource "aws_vpc" "this" {
  count = var.create_scanner_vpc ? 1 : 0

  cidr_block           = var.scanner_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "${local.name}-vpc" })

  lifecycle {
    precondition {
      condition     = local.cloudformation_coexistence_ok
      error_message = local.cloudformation_coexistence_error
    }
  }
}

resource "aws_internet_gateway" "this" {
  count = var.create_scanner_vpc ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  tags = merge(local.tags, { Name = "${local.name}-igw" })
}

resource "aws_subnet" "public" {
  count = var.create_scanner_vpc ? 1 : 0

  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = local.scanner_public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available[0].names[0]
  map_public_ip_on_launch = false

  tags = merge(local.tags, { Name = "${local.name}-public-subnet" })
}

resource "aws_subnet" "private" {
  count = var.create_scanner_vpc ? 1 : 0

  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = local.scanner_private_subnet_cidr
  availability_zone       = data.aws_availability_zones.available[0].names[0]
  map_public_ip_on_launch = false

  tags = merge(local.tags, { Name = "${local.name}-private-subnet" })

  lifecycle {
    precondition {
      condition     = local.scanner_private_subnet_capacity >= local.scanner_peak_task_count
      error_message = "max_concurrent_shards = ${var.max_concurrent_shards} needs ${local.scanner_peak_task_count} concurrent task ENIs (the orchestrator plus its children), but the private subnet ${local.scanner_private_subnet_cidr} carved out of scanner_vpc_cidr only holds ${local.scanner_private_subnet_capacity}. Widen scanner_vpc_cidr or lower max_concurrent_shards."
    }
  }
}

resource "aws_route_table" "public" {
  count = var.create_scanner_vpc ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  tags = merge(local.tags, { Name = "${local.name}-public-rtb" })
}

resource "aws_route" "public_internet" {
  count = var.create_scanner_vpc ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  count = var.create_scanner_vpc ? 1 : 0

  route_table_id = aws_route_table.public[0].id
  subnet_id      = aws_subnet.public[0].id
}

# Stable across NAT Gateway replacements, so customers can allowlist a single
# upstream egress IP in their firewalls instead of the whole Fargate range.
resource "aws_eip" "nat" {
  count = var.create_scanner_vpc ? 1 : 0

  domain = "vpc"

  # The AWS provider documents this dependency for an EIP used in a VPC. Its only
  # other ordering was indirect, through the NAT gateway that consumes it, which
  # left allocation free to race the gateway's creation and left the EIP with no
  # ordering relationship to it at all on destroy.
  #
  # It also puts the EIP behind the VPC, so the coexistence precondition on
  # aws_vpc.this now covers it: a refused apply cannot strand a paid-for address.
  depends_on = [aws_internet_gateway.this]

  tags = merge(local.tags, { Name = "${local.name}-nat-eip" })
}

resource "aws_nat_gateway" "this" {
  count = var.create_scanner_vpc ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  # A NAT Gateway becomes Available as soon as it binds its EIP and ENI, but its
  # outbound traffic uses the public subnet's route table. Without the internet
  # route and the subnet association in place first, the NAT accepts packets and
  # blackholes anything bound for the internet — an easy race for the initial
  # scan firing right after create. Neither dependency is implicit: the NAT only
  # references the EIP and the subnet.
  depends_on = [
    aws_route.public_internet,
    aws_route_table_association.public,
  ]

  tags = merge(local.tags, { Name = "${local.name}-nat" })
}

resource "aws_route_table" "private" {
  count = var.create_scanner_vpc ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  tags = merge(local.tags, { Name = "${local.name}-private-rtb" })
}

resource "aws_route" "private_nat" {
  count = var.create_scanner_vpc ? 1 : 0

  route_table_id         = aws_route_table.private[0].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

resource "aws_route_table_association" "private" {
  count = var.create_scanner_vpc ? 1 : 0

  route_table_id = aws_route_table.private[0].id
  subnet_id      = aws_subnet.private[0].id
}

################################################################################
# Bring-your-own subnet validation (create_scanner_vpc = false)
#
# The Terraform-native replacement for the CloudFormation NetworkPrecheck
# custom resource: refuse to provision the scanner against subnets whose
# 0.0.0.0/0 route is not a NAT Gateway, NAT instance / appliance ENI, VPC
# Endpoint, Transit Gateway, Cloud WAN core network or Outposts local gateway. The
# scanner task always launches with no public IP, so a subnet with only an
# Internet Gateway default route has no way to reach the outside world and
# becomes a black hole. Without this check the task fails later with the opaque
#   "ResourceInitializationError: ... connection issue between the task and
#    Amazon CloudWatch"
# which does not tell the operator the real cause.
#
# Unlike the CloudFormation version this runs at PLAN time, so a bad subnet
# never reaches apply.
################################################################################

data "aws_subnet" "byo" {
  for_each = local.byo_subnets

  id = each.value
}

# AWS associates at most one route table per subnet through an explicit
# association. When there is no explicit association, the VPC's main route table
# applies — resolved separately below.
data "aws_route_tables" "byo_explicit" {
  for_each = local.byo_subnets

  vpc_id = var.vpc_id

  filter {
    name   = "association.subnet-id"
    values = [each.value]
  }
}

# Gated on there being subnets to check as well as on byo_validate, so a caller
# who sets create_scanner_vpc = false and forgets both inputs does not read this
# at all — otherwise a null vpc_id leaves only the association.main filter, which
# matches every VPC in the region and errors with "multiple Route Tables matched"
# instead of the precondition that names the missing input.
#
# vpc_id is an ARGUMENT, not count/for_each, so an unknown value is fine here:
# Terraform simply defers the read. The fallback covers a caller who supplied
# subnets but omitted vpc_id — the subnets themselves name the VPC.
data "aws_route_table" "byo_main" {
  count = local.byo_validate && length(local.byo_subnets) > 0 ? 1 : 0

  vpc_id = var.vpc_id != null ? var.vpc_id : try(values(data.aws_subnet.byo)[0].vpc_id, null)

  filter {
    name   = "association.main"
    values = ["true"]
  }
}

# for_each keys off local.byo_subnets — the same index-keyed map used above — so
# the keys are known whenever the subnet list length is, even when the ids
# themselves are not resolved until apply. Deriving the keys from
# data.aws_route_tables.byo_explicit instead would make them depend on that data
# source's ids, which are unknown at plan for a subnet created in the same
# apply, and Terraform rejects unknown for_each keys outright.
#
# The main-route-table fallback therefore happens here, in route_table_id,
# rather than by filtering the key set: a subnet with no explicit association
# resolves to the VPC's main route table, which is what AWS itself applies.
data "aws_route_table" "byo_explicit" {
  for_each = local.byo_subnets

  route_table_id = try(
    tolist(data.aws_route_tables.byo_explicit[each.key].ids)[0],
    one(data.aws_route_table.byo_main[*].id),
  )
}

################################################################################
# Security Group — egress only
#
# Carries the bring-your-own-subnet preconditions. In the CloudFormation
# template the security group is the anchor every network-touching resource
# depends on, so gating it gates the whole network half of the stack; here the
# preconditions serve the same purpose at plan time.
################################################################################

resource "aws_security_group" "this" {
  name        = "${local.regional_name}-sg"
  description = "Stream Security EBS Scanner - egress only"
  vpc_id      = local.scanner_vpc_id

  tags = merge(local.tags, { Name = "${local.regional_name}-sg" })

  lifecycle {
    precondition {
      condition     = var.create_scanner_vpc || local.byo_enabled
      error_message = "create_scanner_vpc is false, so vpc_id and subnet_ids are both required. Provide existing private subnets with NAT egress, or set create_scanner_vpc = true to have the module provision a VPC with a NAT Gateway."
    }

    precondition {
      condition     = !var.create_scanner_vpc || (var.vpc_id == null && length(var.subnet_ids) == 0)
      error_message = "vpc_id / subnet_ids were supplied while create_scanner_vpc is true, so they would be ignored and the module would provision its own VPC and NAT Gateway (~$32/mo per region). Set create_scanner_vpc = false to use the supplied network, or drop vpc_id and subnet_ids."
    }

    precondition {
      condition     = length(local.byo_wrong_vpc_subnets) == 0
      error_message = "Subnet(s) ${join(", ", local.byo_wrong_vpc_subnets)} are not in VPC ${coalesce(var.vpc_id, "(unset)")}. Pick subnets from the chosen VPC."
    }

    precondition {
      condition     = !local.byo_validate || length(local.byo_subnets) == 0 || local.byo_total_free_ips >= local.scanner_peak_task_count
      error_message = "max_concurrent_shards = ${var.max_concurrent_shards} needs ${local.scanner_peak_task_count} concurrent task ENIs (the orchestrator plus its children), but the supplied subnets have only ${local.byo_total_free_ips} free IP addresses between them. Supply more or larger subnets, or lower max_concurrent_shards."
    }

    precondition {
      condition     = length(local.byo_bad_subnets) == 0
      error_message = <<-EOT
        Scanner subnet check failed: ${join("; ", local.byo_bad_subnets)}.
        Provide a private subnet whose default route targets a NAT Gateway, a NAT instance or appliance ENI, a VPC Endpoint, a Transit Gateway, a Cloud WAN core network, or an Outposts local gateway.
      EOT
    }
  }
}

locals {
  # Same peak-ENI arithmetic as the module-managed subnet, but measured rather
  # than derived: available_ip_address_count is live free capacity, so a subnet
  # shared with other workloads is judged on what is actually left. Fargate in
  # awsvpc mode takes one address per task, and the orchestrator plus every child
  # runs at once.
  #
  # Reported across the whole supplied set, since the scanner spreads tasks over
  # all of them.
  byo_total_free_ips = local.byo_validate ? sum(concat([0], [
    for subnet in data.aws_subnet.byo : subnet.available_ip_address_count
  ])) : 0
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "Allow all outbound - AWS APIs, public ECR, Grype DB, Stream ingest"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
