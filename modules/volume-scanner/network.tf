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
  availability_zone       = local.scanner_az
  map_public_ip_on_launch = false

  tags = merge(local.tags, { Name = "${local.name}-public-subnet" })
}

resource "aws_subnet" "private" {
  count = var.create_scanner_vpc ? 1 : 0

  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = local.scanner_private_subnet_cidr
  availability_zone       = local.scanner_az
  map_public_ip_on_launch = false

  tags = merge(local.tags, { Name = "${local.name}-private-subnet" })

  lifecycle {
    # This sits alongside the capacity check rather than being enforced by
    # scanner_az itself: local.scanner_az falls back to available_azs[0] so the
    # expression stays evaluable, and that fallback would otherwise pick an AZ the
    # endpoint service does not serve and defer the failure to CreateVpcEndpoint.
    precondition {
      condition     = !local.create_ebs_endpoint || length(local.candidate_azs) > 0
      error_message = "No availability zone in ${local.region} offers both a standard AZ and the EBS Direct API interface endpoint service. Set create_ebs_vpc_endpoint = false to deploy without it (snapshot block reads will cross the NAT Gateway), or supply your own subnets with create_scanner_vpc = false."
    }

    precondition {
      condition     = local.scanner_private_subnet_capacity >= local.scanner_peak_task_count
      error_message = "max_concurrent_shards = ${var.max_concurrent_shards} needs ${local.scanner_peak_task_count} concurrent task ENIs (the orchestrator, its children, and the workload child when workload_kinds is set), but the private subnet ${local.scanner_private_subnet_cidr} carved out of scanner_vpc_cidr only holds ${local.scanner_private_subnet_capacity}. Widen scanner_vpc_cidr or lower max_concurrent_shards."
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
# VPC endpoints — keep snapshot block reads off the NAT Gateway
#
# Every ebs:GetSnapshotBlock response is a 512 KiB payload, and in the
# private-subnet layout all of it crosses the NAT at ~$0.045/GiB. Measured on a
# three-instance test fleet in eu-west-1: 3.3 GiB inbound through the NAT for a
# single scan. On a real fleet that dominates the scanner's bill.
#
# An interface endpoint moves that traffic onto PrivateLink at ~$0.01/GiB plus
# ~$7.30/mo for the ENI. PrivateLink keeps the bytes off the NAT and off the
# public internet; it does NOT mean they stay inside the VPC — the ENI is the
# entry point to an AWS-managed service that lives outside it.
#
# The S3 gateway endpoint is free and takes S3-backed ECR layer pulls off the NAT
# during the workload pass. It does not cover public.ecr.aws, which is
# CloudFront-fronted, so the scanner's own image pull still egresses via the NAT.
#
# Bring-your-own-subnet mode deliberately gets none of this: we do not own that
# VPC, and a second S3 gateway endpoint on a route table that already has one
# fails with RouteAlreadyExists. The recommendation is on the subnet_ids input.
################################################################################

resource "aws_security_group" "endpoints" {
  count = local.create_ebs_endpoint ? 1 : 0

  name        = "${local.regional_name}-vpce-sg"
  description = "Stream Security EBS Scanner - HTTPS from the scanner tasks to the VPC endpoints"
  vpc_id      = aws_vpc.this[0].id

  tags = merge(local.tags, { Name = "${local.regional_name}-vpce-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  count = local.create_ebs_endpoint ? 1 : 0

  security_group_id            = aws_security_group.endpoints[0].id
  description                  = "HTTPS from the scanner tasks"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.this.id
}

# Snapshot blocks are read over this instead of the NAT Gateway. PrivateDnsEnabled
# needs the VPC's DNS support and hostnames, both set above, so the EBS Direct API
# hostname resolves to this ENI without the scanner being configured for it.
# Resolved rather than hardcoded as "com.amazonaws.<region>.<svc>": in aws-cn the
# name carries a "cn." prefix, and this module is partition-aware everywhere else.
# Looking it up also fails at PLAN with a clear message where the service does not
# exist, instead of leaving a NAT gateway and Elastic IP billing after a failed
# apply. create_ebs_vpc_endpoint = false is the escape hatch.
data "aws_vpc_endpoint_service" "ebs" {
  count = local.create_ebs_endpoint ? 1 : 0

  # service_name, not the `service` shorthand. The shorthand builds
  # "com.amazonaws.<region>.<svc>" inside the provider, which is exactly the
  # commercial-partition assumption this lookup was introduced to avoid — aws-cn
  # names carry a "cn." prefix. Building it from the partition here and having
  # the data source confirm it keeps both the name AND the plan-time existence
  # check correct in every partition.
  service_name = "${local.vpc_endpoint_service_prefix}com.amazonaws.${local.region}.ebs"
  service_type = "Interface"
}

data "aws_vpc_endpoint_service" "s3" {
  count = local.create_s3_endpoint ? 1 : 0

  # service_type is required alongside service_name, not optional: S3 publishes a
  # Gateway AND an Interface service under the identical name, so filtering on the
  # name alone fails the plan with "multiple EC2 VPC Endpoint Services matched".
  service_name = "${local.vpc_endpoint_service_prefix}com.amazonaws.${local.region}.s3"
  service_type = "Gateway"
}

resource "aws_vpc_endpoint" "ebs" {
  count = local.create_ebs_endpoint ? 1 : 0

  vpc_id              = aws_vpc.this[0].id
  service_name        = data.aws_vpc_endpoint_service.ebs[0].service_name
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.private[0].id]
  security_group_ids  = [aws_security_group.endpoints[0].id]

  tags = merge(local.tags, { Name = "${local.regional_name}-ebs-endpoint" })
}

# Gateway endpoints are free and route S3-backed container image layers away from
# the NAT Gateway.
resource "aws_vpc_endpoint" "s3" {
  count = local.create_s3_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this[0].id
  service_name      = data.aws_vpc_endpoint_service.s3[0].service_name
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private[0].id]

  tags = merge(local.tags, { Name = "${local.regional_name}-s3-endpoint" })
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
# Unlike the CloudFormation version this normally runs at PLAN time, so a bad
# subnet never reaches apply.
#
# "Normally", because a module block carrying `depends_on` — the wiring every
# example in this repo shows — makes Terraform defer the module's data source
# reads whenever the dependency has pending changes. On a first apply, or any
# apply that also changes module.account, these checks therefore move to APPLY
# and a bad subnet can leave the secret, cluster, log group, IAM roles and
# EventBridge rule behind before failing. Applying module.account on its own
# first (see the README) leaves it with no pending changes, and the checks are
# back at plan time.
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

  vpc_id = local.byo_vpc_id != "" ? local.byo_vpc_id : null

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

  vpc_id = local.byo_vpc_id != "" ? local.byo_vpc_id : try(values(data.aws_subnet.byo)[0].vpc_id, null)

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
      condition     = var.create_scanner_vpc || var.create_ebs_vpc_endpoint != true
      error_message = "create_ebs_vpc_endpoint was explicitly set to true while create_scanner_vpc is false, so it would be silently ignored — the module does not create endpoints in a VPC it does not own, and a second S3 gateway endpoint on a route table that already has one fails with RouteAlreadyExists. Leave it unset and add an interface endpoint for the EBS Direct API to your own VPC to get the same saving."
    }

    precondition {
      condition     = !var.create_scanner_vpc || (local.byo_vpc_id == "" && length(local.byo_subnet_ids) == 0)
      error_message = "vpc_id / subnet_ids were supplied while create_scanner_vpc is true, so they would be ignored and the module would provision its own VPC and NAT Gateway (~$32/mo per region). Set create_scanner_vpc = false to use the supplied network, or drop vpc_id and subnet_ids."
    }

    # These two were briefly moved onto the egress rule so that expect_failures
    # could tell "bad subnet" from "bad inputs". That traded a real property for
    # a test convenience: the security group is a dependency of the task
    # definition, the event target and the initial-scan Lambda, whereas the
    # egress rule is a graph leaf — so in the apply-deferred path (see above) the
    # cluster, task definition, secret, log group and four IAM roles would all be
    # created before the check fired. The gate matters more than the assertion
    # precision, so they live here; tests/network.tftest.hcl records what that
    # costs in discrimination.
    precondition {
      condition     = !local.byo_validate || length(local.byo_subnets) == 0 || local.byo_min_free_ips >= local.scanner_peak_task_count
      error_message = "max_concurrent_shards = ${var.max_concurrent_shards} needs ${local.scanner_peak_task_count} concurrent task ENIs (the orchestrator, its children, and the workload child when workload_kinds is set), and ECS placement is best-effort so they can all land in one subnet — but the smallest supplied subnet is sized for only ${local.byo_min_free_ips} addresses after AWS reserves five. Note this measures subnet SIZE, not current free addresses — a large but heavily-used shared subnet can still exhaust at scan time. Supply larger subnets, or lower max_concurrent_shards."
    }

    precondition {
      condition     = length(local.byo_ipv6_only_subnets) == 0
      error_message = "Subnet(s) ${join(", ", local.byo_ipv6_only_subnets)} have no IPv4 CIDR. The scanner task needs an IPv4 address per ENI and reaches the EBS Direct API over IPv4, so an IPv6-only subnet cannot run it."
    }

    precondition {
      condition     = length(local.byo_non_standard_az_subnets) == 0
      error_message = "Subnet(s) ${join(", ", local.byo_non_standard_az_subnets)} are not in a standard availability zone of ${local.region}. Fargate is not offered in Local Zones or Wavelength zones, so every task launch would fail with InvalidParameterException while the install looked healthy."
    }

    precondition {
      condition     = length(local.byo_bad_subnets) == 0
      error_message = <<-EOT
        Scanner subnet check failed: ${join("; ", local.byo_bad_subnets)}.
        Provide a private subnet whose default route targets a NAT Gateway, a NAT instance or appliance ENI, a VPC Endpoint, a Transit Gateway, a Cloud WAN core network, or an Outposts local gateway.
      EOT
    }

    precondition {
      condition     = length(local.byo_wrong_vpc_subnets) == 0
      error_message = "Subnet(s) ${join(", ", local.byo_wrong_vpc_subnets)} are not in VPC ${local.byo_vpc_id != "" ? local.byo_vpc_id : "(unset)"}. Pick subnets from the chosen VPC."
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
  # Sized from the subnet's CIDR, not from available_ip_address_count.
  #
  # The MINIMUM across subnets, not the sum: ECS placement across an awsvpc subnet
  # list is best-effort, so the whole fan-out can land in one subnet, and summing
  # let two 6-address subnets satisfy a peak of 11.
  #
  # But available_ip_address_count is LIVE and drops while the scanner's own
  # children are running, so using it made an apply that overlapped a scan fail a
  # plan-time precondition for a purely transient reason, with a message about
  # subnet sizing that did not explain the timing. Subnet size is stable; AWS
  # reserves five addresses in every subnet.
  # cidr_block is EMPTY for an IPv6-only subnet, so indexing split("/")[1]
  # unguarded aborted the plan with an unattributable "Invalid index" pointing at
  # this locals block. Those subnets are reported by name instead, below.
  # An explicit null check, not coalesce: coalesce("", "") raises "no non-null,
  # non-empty-string arguments" because it skips empty strings too — and an empty
  # cidr_block is exactly the case being detected here.
  byo_subnet_cidrs = {
    for key, subnet in data.aws_subnet.byo :
    key => subnet.cidr_block == null ? "" : subnet.cidr_block
  }

  byo_ipv4_subnets = [
    for key, subnet in data.aws_subnet.byo : subnet
    if length(split("/", local.byo_subnet_cidrs[key])) == 2
  ]

  byo_ipv6_only_subnets = [
    for key, subnet in data.aws_subnet.byo : subnet.id
    if length(split("/", local.byo_subnet_cidrs[key])) != 2
  ]

  byo_min_free_ips = local.byo_validate && length(local.byo_ipv4_subnets) > 0 ? min([
    for subnet in local.byo_ipv4_subnets :
    pow(2, 32 - tonumber(split("/", subnet.cidr_block)[1])) - 5
  ]...) : 0

  # Fargate is not offered in Local Zones or Wavelength zones. The module-managed
  # path filters them out of AZ selection for exactly this reason; bring-your-own
  # never checked, so such a subnet passed everything and then failed every
  # RunTask with InvalidParameterException — a healthy-looking install producing
  # nothing at all. Standard AZ names are "<region><letter>"; Local and Wavelength
  # zones carry an extra "-<city>-<n>" segment.
  byo_non_standard_az_subnets = [
    for key, subnet in data.aws_subnet.byo : subnet.id
    if length(regexall("^${local.region}[a-z]$", subnet.availability_zone)) == 0
  ]
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "Allow all outbound - AWS APIs, public ECR, Grype DB, Stream ingest"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
