# NOTE: `terraform test` on this file needs Terraform >= 1.7 (mock_provider),
# stricter than the module's own required_version. Plan/apply is unaffected.

# Every route object below spells out ALL target fields, including the ones set
# to "": mock_provider generates a random value for any attribute left unset, so
# an omitted nat_gateway_id reads as a real NAT gateway. A new accepted target in
# main.tf means adding it here too. Same for override_data on data.aws_subnet.byo:
# cidr_block AND availability_zone must both be supplied.
mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/mock-scanner-role" }
  }
  # Needed by the `command = apply` runs below: the provider validates these as
  # ARNs, and a generated placeholder fails with "invalid prefix".
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111111111111:cluster/mock-scanner" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:us-east-1:111111111111:task-definition/streamsec-ebs-scanner-tf:1" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  # No CloudFormation-deployed scanner in the region unless a run overrides this.
  mock_data "aws_ecs_clusters" {
    defaults = { cluster_arns = [] }
  }
  # The service name is resolved rather than built from a string, so that aws-cn's
  # "cn." prefix is handled and a missing service fails at plan.
  mock_data "aws_vpc_endpoint_service" {
    defaults = {
      service_name       = "com.amazonaws.us-east-1.resolved"
      availability_zones = ["us-east-1a", "us-east-1b"]
    }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b"] }
  }
  mock_data "aws_subnet" {
    defaults = {
      id                = "subnet-mocked"
      vpc_id            = "vpc-scanner"
      cidr_block        = "10.0.0.0/24"
      availability_zone = "us-east-1a"
    }
  }
  # DNS support ON by default; a run overrides it to prove the check fires.
  mock_data "aws_vpc" {
    defaults = {
      enable_dns_support   = true
      enable_dns_hostnames = true
    }
  }
  mock_data "aws_route_tables" {
    defaults = { ids = ["rtb-explicit"] }
  }
  mock_data "aws_route_table" {
    defaults = {
      routes = [{
        cidr_block                 = "0.0.0.0/0"
        destination_prefix_list_id = ""
        nat_gateway_id             = "nat-abc123"
        gateway_id                 = ""
        transit_gateway_id         = ""
        vpc_endpoint_id            = ""
        network_interface_id       = ""
        instance_id                = ""
        core_network_arn           = ""
        local_gateway_id           = ""
      }]
    }
  }
}

mock_provider "streamsec" {
  mock_data "streamsec_host" {
    defaults = { url = "https://acme.streamsec.io" }
  }
  mock_data "streamsec_aws_account" {
    defaults = {
      cloud_account_id           = "111111111111"
      streamsec_collection_token = "collection-token"
    }
  }
}

mock_provider "archive" {}

variables {
  customer_id = "customer-abc"
}

# command = apply: these compare one resource's argument against another's
# generated id, unknown at plan — under plan the run fails on "Unknown condition
# value" rather than checking the wiring.
run "module_owned_private_subnet_actually_routes_to_the_nat" {
  command = apply

  assert {
    condition = alltrue([
      aws_route.private_nat[0].destination_cidr_block == "0.0.0.0/0",
      aws_route.private_nat[0].nat_gateway_id == aws_nat_gateway.this[0].id,
      aws_route.private_nat[0].route_table_id == aws_route_table.private[0].id,
    ])
    error_message = "The private route table must default-route to the module's NAT Gateway."
  }

  assert {
    condition = alltrue([
      aws_route_table_association.private[0].subnet_id == aws_subnet.private[0].id,
      aws_route_table_association.private[0].route_table_id == aws_route_table.private[0].id,
    ])
    error_message = "The scanner subnet must be associated with the private route table."
  }

  # The NAT must sit in the PUBLIC subnet. In the private one it routes to
  # itself and the failure looks identical to a missing route.
  assert {
    condition     = aws_nat_gateway.this[0].subnet_id == aws_subnet.public[0].id
    error_message = "The NAT Gateway must live in the public subnet."
  }

  assert {
    condition     = aws_route.public_internet[0].gateway_id == aws_internet_gateway.this[0].id
    error_message = "The public route table must default-route to the Internet Gateway."
  }
}

run "default_provisions_the_scanner_vpc" {
  command = plan

  assert {
    condition     = length(aws_vpc.this) == 1 && length(aws_nat_gateway.this) == 1 && length(aws_eip.nat) == 1
    error_message = "Defaults must provision the VPC, NAT Gateway and Elastic IP."
  }

  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.255.0.0/25" && aws_subnet.private[0].cidr_block == "10.255.0.128/25"
    error_message = "The scanner VPC must split into the public/private /25 pair."
  }

  assert {
    condition     = aws_subnet.private[0].map_public_ip_on_launch == false
    error_message = "The private subnet must not assign public IPs."
  }

  assert {
    condition     = aws_subnet.public[0].availability_zone == aws_subnet.private[0].availability_zone
    error_message = "Both subnets must sit in one availability zone."
  }

  assert {
    condition     = aws_cloudwatch_event_target.daily.ecs_target[0].network_configuration[0].assign_public_ip == false
    error_message = "The scheduled task must launch with no public IP."
  }
}

# A /27 halves into a /28 private subnet: 16 addresses, 5 reserved by AWS and 1
# for the EBS endpoint ENI leaves 10, so 20 children do not fit.
run "concurrency_beyond_the_subnet_capacity_is_rejected" {
  command = plan

  variables {
    scanner_vpc_cidr      = "10.255.0.0/27"
    max_concurrent_shards = 20
  }

  expect_failures = [aws_subnet.private]
}

run "concurrency_within_the_subnet_capacity_is_accepted" {
  command = plan

  variables {
    scanner_vpc_cidr      = "10.255.0.0/27"
    max_concurrent_shards = 8
  }

  assert {
    condition     = aws_subnet.private[0].cidr_block == "10.255.0.16/28"
    error_message = "8 shards plus orchestrator, workload child and endpoint ENI must fit the /28."
  }
}

# The EBS interface endpoint puts an ENI of its own in the private subnet; miss
# it and the last child task fails with an opaque ResourceInitializationError.
run "endpoint_eni_is_counted_against_subnet_capacity" {
  command = plan

  variables {
    scanner_vpc_cidr      = "10.255.0.0/27"
    max_concurrent_shards = 10
  }

  expect_failures = [aws_subnet.private]
}

run "same_config_fits_once_the_endpoint_is_disabled" {
  command = plan

  variables {
    scanner_vpc_cidr        = "10.255.0.0/27"
    max_concurrent_shards   = 9
    create_ebs_vpc_endpoint = false
  }

  assert {
    condition     = length(aws_vpc_endpoint.ebs) == 0
    error_message = "With the endpoint disabled the same concurrency must fit the /28."
  }
}

# With workload_kinds non-empty the orchestrator also launches a dedicated
# workload child, so the same concurrency needs one more ENI.
run "workload_child_task_is_counted_against_capacity" {
  command = plan

  variables {
    scanner_vpc_cidr      = "10.255.0.0/27"
    max_concurrent_shards = 9
    workload_kinds        = ""
  }

  assert {
    condition     = aws_subnet.private[0].cidr_block == "10.255.0.16/28"
    error_message = "With workload scanning off, orchestrator + 9 children must fit the /28."
  }
}

run "same_concurrency_no_longer_fits_once_workloads_are_scanned" {
  command = plan

  variables {
    scanner_vpc_cidr      = "10.255.0.0/27"
    max_concurrent_shards = 9
    workload_kinds        = "ecs"
  }

  expect_failures = [aws_subnet.private]
}

run "the_default_cidr_holds_the_maximum_concurrency" {
  command = plan

  variables {
    max_concurrent_shards = 100
  }

  assert {
    condition     = aws_subnet.private[0].cidr_block == "10.255.0.128/25"
    error_message = "The default CIDR must hold max_concurrent_shards at its ceiling."
  }
}

run "vpc_endpoints_are_created_by_default" {
  command = plan

  assert {
    condition = alltrue([
      length(aws_vpc_endpoint.ebs) == 1,
      length(aws_vpc_endpoint.s3) == 1,
      length(aws_security_group.endpoints) == 1,
    ])
    error_message = "The EBS interface and S3 gateway endpoints must be on by default."
  }

  assert {
    condition     = aws_vpc_endpoint.ebs[0].service_name == data.aws_vpc_endpoint_service.ebs[0].service_name && aws_vpc_endpoint.ebs[0].vpc_endpoint_type == "Interface" && aws_vpc_endpoint.ebs[0].private_dns_enabled == true
    error_message = "The EBS endpoint must use the resolved service name, Interface type and private DNS."
  }

  assert {
    condition     = aws_vpc_endpoint.s3[0].vpc_endpoint_type == "Gateway"
    error_message = "The S3 endpoint must be a Gateway endpoint."
  }
}

# An explicit true in bring-your-own-subnet mode is a misunderstanding worth a
# diagnostic; leaving it unset there must stay silent.
run "endpoints_requested_in_byo_mode_are_rejected" {
  command = plan

  variables {
    create_scanner_vpc      = false
    vpc_id                  = "vpc-scanner"
    subnet_ids              = ["subnet-private-a"]
    create_ebs_vpc_endpoint = true
  }

  expect_failures = [aws_security_group.this]
}

# AZ names map to different physical AZs per account and the endpoint service is
# not offered in every AZ, so the AZ must come from the intersection, not names[0].
run "scanner_az_comes_from_the_endpoint_service_zones" {
  command = plan

  override_data {
    target = data.aws_vpc_endpoint_service.ebs[0]
    values = {
      service_name       = "com.amazonaws.us-east-1.resolved"
      availability_zones = ["us-east-1b"]
    }
  }

  assert {
    condition     = aws_subnet.private[0].availability_zone == "us-east-1b"
    error_message = "The subnet must land in an AZ the EBS endpoint service serves."
  }
}

run "no_overlapping_az_is_refused_before_the_nat_is_built" {
  command = plan

  override_data {
    target = data.aws_vpc_endpoint_service.ebs[0]
    values = {
      service_name       = "com.amazonaws.us-east-1.resolved"
      availability_zones = ["us-east-1-nowhere"]
    }
  }

  expect_failures = [aws_subnet.private]
}

run "ebs_endpoint_can_be_disabled_without_losing_s3" {
  command = plan

  variables {
    create_ebs_vpc_endpoint = false
  }

  assert {
    condition = alltrue([
      length(aws_vpc_endpoint.ebs) == 0,
      length(aws_security_group.endpoints) == 0,
      # The free gateway endpoint survives: the opt-out exists for a missing EBS
      # interface service, and dropping S3 puts ECR layer pulls back on the NAT.
      length(aws_vpc_endpoint.s3) == 1,
    ])
    error_message = "create_ebs_vpc_endpoint = false must drop only the interface endpoint and its SG."
  }
}

# We do not own the caller's VPC, and a second S3 gateway endpoint on a route
# table that already has one fails with RouteAlreadyExists. Fargate is not offered
# in Local Zones or Wavelength zones. And with enableDnsSupport off, nothing the
# task resolves — plan is clean, apply succeeds, every scan fails on DNS.
run "byo_vpc_without_dns_support_is_rejected" {
  command = plan

  variables {
    create_scanner_vpc = false
    vpc_id             = "vpc-scanner"
    subnet_ids         = ["subnet-private-a"]
  }

  override_data {
    target = data.aws_vpc.byo[0]
    values = {
      enable_dns_support   = false
      enable_dns_hostnames = true
    }
  }

  expect_failures = [aws_security_group.this]
}

run "byo_subnet_in_a_local_zone_is_rejected" {
  command = plan

  variables {
    create_scanner_vpc = false
    vpc_id             = "vpc-scanner"
    subnet_ids         = ["subnet-localzone"]
  }

  override_data {
    target = data.aws_subnet.byo["0"]
    values = {
      vpc_id            = "vpc-scanner"
      cidr_block        = "10.0.0.0/24"
      availability_zone = "us-east-1-bos-1a"
    }
  }

  expect_failures = [aws_security_group.this]
}

# cidr_block is empty for an IPv6-only subnet, which used to abort the plan on an
# unguarded split("/")[1] instead of naming the subnet.
run "byo_ipv6_only_subnet_is_reported_not_crashed" {
  command = plan

  variables {
    create_scanner_vpc = false
    vpc_id             = "vpc-scanner"
    subnet_ids         = ["subnet-ipv6only"]
  }

  override_data {
    target = data.aws_subnet.byo["0"]
    values = {
      vpc_id            = "vpc-scanner"
      cidr_block        = ""
      availability_zone = "us-east-1a"
    }
  }

  expect_failures = [aws_security_group.this]
}

# Mutation-checked: emptying the BYO branch of local.scanner_subnet_ids used to
# pass every run, because nothing asserted the subnets reach the fan-out.
run "byo_subnets_reach_the_fan_out_wiring" {
  command = apply

  variables {
    create_scanner_vpc = false
    vpc_id             = "vpc-scanner"
    subnet_ids         = ["subnet-private-a", " subnet-private-b "]
  }

  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${e.name}=${e.value}"], "COLLECTOR_ECS_SUBNET_IDS=subnet-private-a,subnet-private-b")
    error_message = "The supplied subnet ids must reach COLLECTOR_ECS_SUBNET_IDS, trimmed."
  }

  # subnets is a SET, so it is compared by membership and size rather than by
  # equality against a tuple, which fails on type.
  assert {
    condition = alltrue([
      length(aws_cloudwatch_event_target.daily.ecs_target[0].network_configuration[0].subnets) == 2,
      contains(aws_cloudwatch_event_target.daily.ecs_target[0].network_configuration[0].subnets, "subnet-private-a"),
      contains(aws_cloudwatch_event_target.daily.ecs_target[0].network_configuration[0].subnets, "subnet-private-b"),
    ])
    error_message = "The scheduled target must launch into the supplied subnets, trimmed."
  }
}

run "byo_mode_creates_no_endpoints" {
  command = plan

  variables {
    create_scanner_vpc = false
    vpc_id             = "vpc-scanner"
    subnet_ids         = ["subnet-private-a"]
  }

  assert {
    condition = alltrue([
      length(aws_vpc_endpoint.ebs) == 0,
      length(aws_vpc_endpoint.s3) == 0,
      length(aws_security_group.endpoints) == 0,
    ])
    error_message = "Bring-your-own-subnet mode must create no VPC endpoints."
  }
}

run "byo_subnet_with_nat_egress_is_accepted" {
  command = plan

  variables {
    create_scanner_vpc = false
    vpc_id             = "vpc-scanner"
    subnet_ids         = ["subnet-private-a"]
  }

  assert {
    condition     = length(aws_vpc.this) == 0 && length(aws_nat_gateway.this) == 0
    error_message = "create_scanner_vpc = false must provision no network infrastructure."
  }

  assert {
    condition     = aws_security_group.this.vpc_id == "vpc-scanner"
    error_message = "The security group must be created in the supplied VPC."
  }
}

run "byo_subnet_behind_a_transit_gateway_is_accepted" {
  command = plan

  variables {
    create_scanner_vpc = false
    vpc_id             = "vpc-scanner"
    subnet_ids         = ["subnet-private-a"]
  }

  override_data {
    target = data.aws_route_table.byo_explicit["0"]
    values = {
      routes = [{
        cidr_block                 = "0.0.0.0/0"
        destination_prefix_list_id = ""
        nat_gateway_id             = ""
        gateway_id                 = ""
        transit_gateway_id         = "tgw-abc123"
        vpc_endpoint_id            = ""
        network_interface_id       = ""
        instance_id                = ""
        core_network_arn           = ""
        local_gateway_id           = ""
      }]
    }
  }

  assert {
    condition     = aws_security_group.this.vpc_id == "vpc-scanner"
    error_message = "A Transit Gateway default route must be accepted as egress."
  }
}

# NOTE: every bring-your-own failure below names aws_security_group.this, which
# carries six preconditions, so any one of them satisfies the assertion —
# deliberate: moving the checks to a leaf resource weakened the gate in the
# apply-deferred path. So this proves an IGW-only subnet is rejected, but not
# that the public-subnet wording survives; that wording is a format() branch
# inside byo_bad_subnets, not its own precondition.
run "byo_igw_only_subnet_is_rejected" {
  command = plan

  variables {
    create_scanner_vpc = false
    vpc_id             = "vpc-scanner"
    subnet_ids         = ["subnet-public-a"]
  }

  override_data {
    target = data.aws_route_table.byo_explicit["0"]
    values = {
      routes = [{
        cidr_block                 = "0.0.0.0/0"
        destination_prefix_list_id = ""
        nat_gateway_id             = ""
        gateway_id                 = "igw-abc123"
        transit_gateway_id         = ""
        vpc_endpoint_id            = ""
        network_interface_id       = ""
        instance_id                = ""
        core_network_arn           = ""
        local_gateway_id           = ""
      }]
    }
  }

  expect_failures = [aws_security_group.this]
}

run "byo_subnet_without_a_default_route_is_rejected" {
  command = plan

  variables {
    create_scanner_vpc = false
    vpc_id             = "vpc-scanner"
    subnet_ids         = ["subnet-isolated-a"]
  }

  override_data {
    target = data.aws_route_table.byo_explicit["0"]
    values = {
      routes = [{
        cidr_block                 = "10.0.0.0/16"
        destination_prefix_list_id = ""
        nat_gateway_id             = ""
        gateway_id                 = "local"
        transit_gateway_id         = ""
        vpc_endpoint_id            = ""
        network_interface_id       = ""
        instance_id                = ""
        core_network_arn           = ""
        local_gateway_id           = ""
      }]
    }
  }

  expect_failures = [aws_security_group.this]
}

run "byo_subnet_in_another_vpc_is_rejected" {
  command = plan

  variables {
    create_scanner_vpc = false
    vpc_id             = "vpc-scanner"
    subnet_ids         = ["subnet-elsewhere"]
  }

  override_data {
    target = data.aws_subnet.byo["0"]
    values = {
      vpc_id            = "vpc-somewhere-else"
      cidr_block        = "10.9.0.0/24"
      availability_zone = "us-east-1a"
    }
  }

  expect_failures = [aws_security_group.this]
}

run "byo_mode_requires_vpc_and_subnets" {
  command = plan

  variables {
    create_scanner_vpc = false
  }

  expect_failures = [aws_security_group.this]
}

run "byo_subnet_behind_a_nat_instance_is_accepted" {
  command = plan

  variables {
    create_scanner_vpc = false
    vpc_id             = "vpc-scanner"
    subnet_ids         = ["subnet-private-a"]
  }

  override_data {
    target = data.aws_route_table.byo_explicit["0"]
    values = {
      routes = [{
        cidr_block                 = "0.0.0.0/0"
        destination_prefix_list_id = ""
        nat_gateway_id             = ""
        gateway_id                 = ""
        transit_gateway_id         = ""
        vpc_endpoint_id            = ""
        network_interface_id       = "eni-abc123"
        instance_id                = "i-abc123"
        core_network_arn           = ""
        local_gateway_id           = ""
      }]
    }
  }

  assert {
    condition     = aws_security_group.this.vpc_id == "vpc-scanner"
    error_message = "A NAT instance or appliance ENI default route must be accepted as egress."
  }
}

run "byo_subnet_behind_cloud_wan_is_accepted" {
  command = plan

  variables {
    create_scanner_vpc = false
    vpc_id             = "vpc-scanner"
    subnet_ids         = ["subnet-private-a"]
  }

  override_data {
    target = data.aws_route_table.byo_explicit["0"]
    values = {
      routes = [{
        cidr_block                 = "0.0.0.0/0"
        destination_prefix_list_id = ""
        nat_gateway_id             = ""
        gateway_id                 = ""
        transit_gateway_id         = ""
        vpc_endpoint_id            = ""
        network_interface_id       = ""
        instance_id                = ""
        local_gateway_id           = ""
        core_network_arn           = "arn:aws:networkmanager::111111111111:core-network/core-network-abc"
      }]
    }
  }

  assert {
    condition     = aws_security_group.this.vpc_id == "vpc-scanner"
    error_message = "A Cloud WAN core-network default route must be accepted as egress."
  }
}

# NOTE: this asserts both supplied subnets are validated. It does NOT reproduce
# the unknown-at-plan vpc_id regression — a `variables` block can only supply
# known values — which is covered out-of-band by a root-module harness. See the
# note in README.md under Tests.
run "byo_subnets_are_each_validated" {
  command = plan

  variables {
    create_scanner_vpc = false
    vpc_id             = "vpc-scanner"
    subnet_ids         = ["subnet-a", "subnet-b"]
  }

  assert {
    condition     = length(data.aws_subnet.byo) == 2
    error_message = "Both supplied subnets must be validated; the for_each gate must not read vpc_id."
  }
}

run "byo_subnet_behind_a_virtual_private_gateway_is_accepted" {
  command = plan

  variables {
    create_scanner_vpc = false
    vpc_id             = "vpc-scanner"
    subnet_ids         = ["subnet-private-a"]
  }

  override_data {
    target = data.aws_route_table.byo_explicit["0"]
    values = {
      routes = [{
        cidr_block                 = "0.0.0.0/0"
        destination_prefix_list_id = ""
        nat_gateway_id             = ""
        gateway_id                 = "vgw-abc123"
        transit_gateway_id         = ""
        vpc_endpoint_id            = ""
        network_interface_id       = ""
        instance_id                = ""
        core_network_arn           = ""
        local_gateway_id           = ""
      }]
    }
  }

  assert {
    condition     = aws_security_group.this.vpc_id == "vpc-scanner"
    error_message = "A virtual private gateway default route must be accepted as egress."
  }
}

run "byo_subnet_too_small_for_peak_concurrency_is_rejected" {
  command = plan

  variables {
    create_scanner_vpc    = false
    vpc_id                = "vpc-scanner"
    subnet_ids            = ["subnet-private-a"]
    max_concurrent_shards = 50
  }

  # A /28 holds 16 addresses, 5 reserved, so 11 usable — short of the 52 that 50
  # shards plus the orchestrator plus the workload child need.
  override_data {
    target = data.aws_subnet.byo["0"]
    values = {
      vpc_id            = "vpc-scanner"
      cidr_block        = "10.0.0.0/28"
      availability_zone = "us-east-1a"
    }
  }

  expect_failures = [aws_security_group.this]
}

# An isolated private subnet whose ONLY non-local route is the S3 gateway
# endpoint: common in enterprise private subnets, and not internet egress.
run "s3_gateway_endpoint_route_is_not_egress" {
  command = plan

  variables {
    create_scanner_vpc = false
    vpc_id             = "vpc-scanner"
    subnet_ids         = ["subnet-isolated-a"]
  }

  override_data {
    target = data.aws_route_table.byo_explicit["0"]
    values = {
      routes = [{
        cidr_block                 = ""
        destination_prefix_list_id = "pl-63a5400a"
        gateway_id                 = "vpce-0123456789abcdef0"
        nat_gateway_id             = ""
        transit_gateway_id         = ""
        vpc_endpoint_id            = ""
        network_interface_id       = ""
        instance_id                = ""
        core_network_arn           = ""
        local_gateway_id           = ""
      }]
    }
  }

  expect_failures = [aws_security_group.this]
}

# A genuinely public subnet that also carries the S3 gateway endpoint route: the
# prefix-list rule set has_egress = true and short-circuited the IGW rejection.
run "public_subnet_with_an_s3_endpoint_is_still_rejected" {
  command = plan

  variables {
    create_scanner_vpc = false
    vpc_id             = "vpc-scanner"
    subnet_ids         = ["subnet-public-a"]
  }

  override_data {
    target = data.aws_route_table.byo_explicit["0"]
    values = {
      routes = [
        {
          cidr_block                 = "0.0.0.0/0"
          destination_prefix_list_id = ""
          gateway_id                 = "igw-abc123"
          nat_gateway_id             = ""
          transit_gateway_id         = ""
          vpc_endpoint_id            = ""
          network_interface_id       = ""
          instance_id                = ""
          core_network_arn           = ""
          local_gateway_id           = ""
        },
        {
          cidr_block                 = ""
          destination_prefix_list_id = "pl-63a5400a"
          gateway_id                 = "vpce-0123456789abcdef0"
          nat_gateway_id             = ""
          transit_gateway_id         = ""
          vpc_endpoint_id            = ""
          network_interface_id       = ""
          instance_id                = ""
          core_network_arn           = ""
          local_gateway_id           = ""
        },
      ]
    }
  }

  expect_failures = [aws_security_group.this]
}

run "supplying_a_vpc_while_creating_one_is_rejected" {
  command = plan

  variables {
    vpc_id     = "vpc-someone-elses"
    subnet_ids = ["subnet-someone-elses"]
  }

  expect_failures = [aws_security_group.this]
}

run "egress_validation_can_be_skipped" {
  command = plan

  variables {
    create_scanner_vpc     = false
    vpc_id                 = "vpc-scanner"
    subnet_ids             = ["subnet-private-a"]
    validate_subnet_egress = false
  }

  assert {
    condition     = length(data.aws_route_table.byo_main) == 0 && length(data.aws_subnet.byo) == 0
    error_message = "validate_subnet_egress = false must read no validation data sources."
  }
}

# These assert a blank vpc_id trips the module's own preconditions. They do NOT
# guard the data-source wiring: mock_provider returns data for any filter, so
# reverting the consumers to raw var.vpc_id leaves both green — verified.
run "blank_vpc_id_is_caught_by_the_precondition_not_a_data_source" {
  command = plan

  variables {
    create_scanner_vpc = false
    vpc_id             = "   "
    subnet_ids         = ["subnet-private-a"]
  }

  expect_failures = [aws_security_group.this]
}

run "blank_vpc_id_also_trips_the_create_scanner_vpc_conflict" {
  command = plan

  variables {
    create_scanner_vpc = true
    vpc_id             = "vpc-scanner"
  }

  expect_failures = [aws_security_group.this]
}
