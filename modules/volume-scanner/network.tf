################################################################################
# Dedicated scanner VPC (create_scanner_vpc = true)
# Single AZ deliberately: the one NAT means an AZ outage kills egress anyway.
################################################################################

data "aws_availability_zones" "available" {
  count = var.create_scanner_vpc ? 1 : 0
  state = "available"

  # Local Zones sort before real AZs in `names` and cannot run Fargate.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# Repeated: the VPC does not depend on the cluster, so a refused apply would
# otherwise strand the VPC, NAT and EIP.
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

  vpc_id            = aws_vpc.this[0].id
  cidr_block        = local.scanner_public_subnet_cidr
  availability_zone = local.scanner_az

  # False where the CloudFormation template sets true: only the NAT lives here.
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
    # Checked here because local.scanner_az falls back to available_azs[0], which
    # would otherwise defer the failure to CreateVpcEndpoint.
    precondition {
      condition     = !local.create_ebs_endpoint || length(local.candidate_azs) > 0
      error_message = "No availability zone in ${local.region} offers both a standard AZ and the EBS Direct API interface endpoint service. Set create_ebs_vpc_endpoint = false to deploy without it, or supply your own subnets with create_scanner_vpc = false."
    }

    precondition {
      condition     = local.scanner_private_subnet_capacity >= local.scanner_peak_task_count
      error_message = "max_concurrent_shards = ${var.max_concurrent_shards} needs ${local.scanner_peak_task_count} concurrent task ENIs, but the private subnet ${local.scanner_private_subnet_cidr} holds only ${local.scanner_private_subnet_capacity}. Widen scanner_vpc_cidr or lower max_concurrent_shards."
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

# Stable across NAT replacements, so customers can allowlist one egress IP.
resource "aws_eip" "nat" {
  count = var.create_scanner_vpc ? 1 : 0

  domain = "vpc"

  # Provider-documented for a VPC EIP; also puts it behind the VPC's guard.
  depends_on = [aws_internet_gateway.this]

  tags = merge(local.tags, { Name = "${local.name}-nat-eip" })
}

resource "aws_nat_gateway" "this" {
  count = var.create_scanner_vpc ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  # Not implicit: the NAT goes Available and blackholes internet-bound packets
  # until the public route table is wired.
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
# VPC endpoints - keep snapshot block reads and ECR layer pulls off the NAT
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

# Looked up so a region without the service fails at plan, before billing starts.
data "aws_vpc_endpoint_service" "ebs" {
  count = local.create_ebs_endpoint ? 1 : 0

  # service_name, not the `service` shorthand: aws-cn names carry a "cn." prefix.
  service_name = "${local.vpc_endpoint_service_prefix}com.amazonaws.${local.region}.ebs"
  service_type = "Interface"
}

data "aws_vpc_endpoint_service" "s3" {
  count = local.create_s3_endpoint ? 1 : 0

  # service_type is required: S3 publishes a Gateway and an Interface service
  # under the same name.
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
# The task has no public IP, so a subnet without NAT-style egress is a black hole
# and fails later with an opaque ResourceInitializationError.
################################################################################

data "aws_subnet" "byo" {
  for_each = local.byo_subnets

  id = each.value
}

# With no explicit association the VPC's main route table applies (resolved below).
data "aws_route_tables" "byo_explicit" {
  for_each = local.byo_subnets

  vpc_id = local.byo_vpc_id != "" ? local.byo_vpc_id : null

  filter {
    name   = "association.subnet-id"
    values = [each.value]
  }
}

data "aws_vpc" "byo" {
  count = local.byo_validate && length(local.byo_subnets) > 0 ? 1 : 0

  # No try(..., null) fallback: aws_vpc with all arguments null resolves to the
  # account's DEFAULT VPC.
  id = values(data.aws_subnet.byo)[0].vpc_id
}

data "aws_route_table" "byo_main" {
  count = local.byo_validate && length(local.byo_subnets) > 0 ? 1 : 0

  vpc_id = local.byo_vpc_id != "" ? local.byo_vpc_id : try(values(data.aws_subnet.byo)[0].vpc_id, null)

  filter {
    name   = "association.main"
    values = ["true"]
  }
}

# Keyed off local.byo_subnets so the keys are known at plan; keying off the route
# table data source makes them unknown, which for_each rejects. The main-route-table
# fallback therefore lives in route_table_id, not in the key set.
data "aws_route_table" "byo_explicit" {
  for_each = local.byo_subnets

  route_table_id = try(
    tolist(data.aws_route_tables.byo_explicit[each.key].ids)[0],
    one(data.aws_route_table.byo_main[*].id),
  )
}

################################################################################
# Security Group - egress only, and the bring-your-own-subnet preconditions
################################################################################

resource "aws_security_group" "this" {
  name        = "${local.regional_name}-sg"
  description = "Stream Security EBS Scanner - egress only"
  vpc_id      = local.scanner_vpc_id

  tags = merge(local.tags, { Name = "${local.regional_name}-sg" })

  lifecycle {
    precondition {
      condition     = var.create_scanner_vpc || local.byo_enabled
      error_message = "create_scanner_vpc = false requires both vpc_id and subnet_ids. Supply existing private subnets with NAT egress, or set create_scanner_vpc = true."
    }

    precondition {
      condition     = var.create_scanner_vpc || var.create_ebs_vpc_endpoint != true
      error_message = "create_ebs_vpc_endpoint = true is ignored when create_scanner_vpc = false: the module does not create endpoints in a VPC it does not own. Leave it unset and add an EBS Direct API interface endpoint to your own VPC."
    }

    precondition {
      condition     = !var.create_scanner_vpc || (local.byo_vpc_id == "" && length(local.byo_subnet_ids) == 0)
      error_message = "vpc_id / subnet_ids were supplied while create_scanner_vpc is true, so they would be ignored. Set create_scanner_vpc = false to use the supplied network, or drop vpc_id and subnet_ids."
    }

    precondition {
      # length(byo_ipv4_subnets) == 0 short-circuits BEFORE the comparison: with an
      # all-IPv6 list byo_min_free_ips falls back to the literal 0, so this fired
      # too and told the operator to "supply larger subnets", which cannot fix a
      # subnet with no IPv4 CIDR. The IPv6 precondition below is the real report.
      condition     = !local.byo_validate || length(local.byo_subnets) == 0 || length(local.byo_ipv4_subnets) == 0 || local.byo_min_free_ips >= local.scanner_peak_task_count
      error_message = "max_concurrent_shards = ${var.max_concurrent_shards} needs ${local.scanner_peak_task_count} concurrent task ENIs that can all land in one subnet, but the smallest supplied subnet is sized for only ${local.byo_min_free_ips} addresses after AWS's five reserved. Supply larger subnets, or lower max_concurrent_shards."
    }

    # coalesce, NOT try: one([]) is null and try() catches errors, not nulls, so
    # try(one(...), true) yields null, which || rejects before Terraform 1.12.
    precondition {
      condition     = !local.byo_validate || length(local.byo_subnets) == 0 || coalesce(one(data.aws_vpc.byo[*].enable_dns_support), true)
      error_message = "VPC ${local.byo_vpc_id != "" ? local.byo_vpc_id : "(supplied subnets')"} has enableDnsSupport disabled. The scanner resolves the EBS Direct API and the Stream ingest host through the VPC resolver; enable DNS support."
    }

    precondition {
      condition     = length(local.byo_ipv6_only_subnets) == 0
      error_message = "Subnet(s) ${join(", ", local.byo_ipv6_only_subnets)} have no IPv4 CIDR. The scanner task needs an IPv4 address per ENI; supply dual-stack or IPv4 subnets."
    }

    precondition {
      condition     = length(local.byo_non_standard_az_subnets) == 0
      error_message = "Subnet(s) ${join(", ", local.byo_non_standard_az_subnets)} are not in a standard availability zone of ${local.region}. Fargate is not offered in Local Zones or Wavelength zones; supply subnets in a standard AZ."
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
  # cidr_block is EMPTY for an IPv6-only subnet, which would abort the plan on
  # split("/")[1]. An explicit null check, not coalesce, which skips "" and raises.
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

  # MINIMUM, not sum: ECS placement is best-effort so the whole fan-out can land in
  # one subnet. From the CIDR, not available_ip_address_count, which is live.
  byo_min_free_ips = local.byo_validate && length(local.byo_ipv4_subnets) > 0 ? min([
    for subnet in local.byo_ipv4_subnets :
    pow(2, 32 - tonumber(split("/", subnet.cidr_block)[1])) - 5
  ]...) : 0

  # Fargate is not offered in Local Zones or Wavelength zones, whose names carry an
  # extra "-<city>-<n>" segment.
  byo_non_standard_az_subnets = [
    for key, subnet in data.aws_subnet.byo : subnet.id
    if length(regexall("^${local.region}[a-z]$", subnet.availability_zone)) == 0
  ]
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  # All protocols for now: SG egress also governs DNS to the VPC resolver.
  description = "Allow all outbound - AWS APIs, public ECR, Grype DB, Stream ingest, and DNS to the VPC resolver"
  ip_protocol = "-1"
  cidr_ipv4   = "0.0.0.0/0"
}
