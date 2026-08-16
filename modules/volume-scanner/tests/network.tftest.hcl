# NOTE: running these tests requires Terraform >= 1.7 (mock_provider blocks) —
# stricter than the module's own required_version. Older versions fail to parse
# this file when running `terraform test`; plan/apply of the module itself is
# unaffected, tests/ is ignored there.

# Every route object below spells out ALL target fields, including the ones set
# to "". mock_provider generates a random value for any attribute left unset —
# nested attributes included — so an omitted nat_gateway_id reads as a real NAT
# gateway and an egress-less subnet is silently accepted. Adding a new accepted
# target in main.tf means adding it here too.
mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/mock-scanner-role" }
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
    defaults = { service_name = "com.amazonaws.us-east-1.resolved" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b"] }
  }
  mock_data "aws_subnet" {
    defaults = {
      id                         = "subnet-mocked"
      vpc_id                     = "vpc-scanner"
      available_ip_address_count = 251
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

run "default_provisions_the_scanner_vpc" {
  command = plan

  assert {
    condition     = length(aws_vpc.this) == 1 && length(aws_nat_gateway.this) == 1 && length(aws_eip.nat) == 1
    error_message = "With defaults the module must provision its own VPC with a NAT Gateway and an Elastic IP."
  }

  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.255.0.0/25" && aws_subnet.private[0].cidr_block == "10.255.0.128/25"
    error_message = "The scanner VPC must split into the same public/private /25 pair the CloudFormation template uses."
  }

  assert {
    condition     = aws_subnet.private[0].map_public_ip_on_launch == false
    error_message = "The private subnet must not assign public IPs — the scanner task runs without one."
  }

  assert {
    condition     = aws_subnet.public[0].availability_zone == aws_subnet.private[0].availability_zone
    error_message = "Both subnets must sit in a single availability zone, so one NAT Gateway serves the scanner."
  }

  assert {
    condition     = aws_cloudwatch_event_target.daily.ecs_target[0].network_configuration[0].assign_public_ip == false
    error_message = "The scheduled task must launch with no public IP in either network mode."
  }
}

# A /27 VPC halves into a /28 private subnet: 16 addresses, 5 reserved by AWS and
# 1 taken by the EBS endpoint ENI, leaving 10. 20 children plus the orchestrator
# does not fit.
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
    max_concurrent_shards = 9
  }

  assert {
    condition     = aws_subnet.private[0].cidr_block == "10.255.0.16/28"
    error_message = "A /28 holds 16 addresses: 5 reserved by AWS and 1 for the EBS endpoint ENI leaves 10, so 9 children plus the orchestrator must fit."
  }
}

# The EBS interface endpoint puts an ENI of its own in the private subnet. Miss
# it and the capacity check passes at exactly the boundary while the last child
# task fails ENI provisioning with an opaque ResourceInitializationError.
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
    max_concurrent_shards   = 10
    create_ebs_vpc_endpoint = false
  }

  assert {
    condition     = length(aws_vpc_endpoint.ebs) == 0
    error_message = "With no endpoint ENI the /28's full 11 usable addresses are available, so the same concurrency fits — proving the capacity maths tracks the endpoint rather than being a blanket reduction."
  }
}

run "the_default_cidr_holds_the_maximum_concurrency" {
  command = plan

  variables {
    max_concurrent_shards = 100
  }

  assert {
    condition     = aws_subnet.private[0].cidr_block == "10.255.0.128/25"
    error_message = "The default scanner_vpc_cidr must hold max_concurrent_shards at its ceiling, so the capacity check never fires on defaults."
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
    error_message = "Snapshot block reads are the dominant egress cost, so the EBS interface endpoint and the free S3 gateway endpoint must be on by default."
  }

  assert {
    condition     = aws_vpc_endpoint.ebs[0].service_name == data.aws_vpc_endpoint_service.ebs[0].service_name && aws_vpc_endpoint.ebs[0].vpc_endpoint_type == "Interface" && aws_vpc_endpoint.ebs[0].private_dns_enabled == true
    error_message = "The EBS endpoint must take its service name from the resolver (so aws-cn's cn. prefix works) and be an interface endpoint with private DNS — without private DNS the EBS Direct API hostname does not resolve to it and traffic silently stays on the NAT."
  }

  assert {
    condition     = aws_vpc_endpoint.s3[0].vpc_endpoint_type == "Gateway"
    error_message = "The S3 endpoint must be a gateway endpoint — it is free and attaches to the private route table."
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

run "ebs_endpoint_can_be_disabled_without_losing_s3" {
  command = plan

  variables {
    create_ebs_vpc_endpoint = false
  }

  assert {
    condition = alltrue([
      length(aws_vpc_endpoint.ebs) == 0,
      length(aws_security_group.endpoints) == 0,
      # The free gateway endpoint survives. The opt-out exists for a missing EBS
      # interface service; dropping S3 too would put ECR layer pulls back on the
      # NAT for no reason.
      length(aws_vpc_endpoint.s3) == 1,
    ])
    error_message = "create_ebs_vpc_endpoint = false must drop only the interface endpoint and its security group, leaving the free S3 gateway endpoint in place."
  }
}

# We do not own the caller's VPC, and a second S3 gateway endpoint on a route
# table that already has one fails with RouteAlreadyExists.
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
    error_message = "Bring-your-own-subnet mode must create no VPC endpoints in a VPC the module does not own."
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
    error_message = "With create_scanner_vpc = false the module must not provision any network infrastructure."
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
    error_message = "A Transit Gateway default route must be accepted — it may egress through a central-egress VPC, which is not knowable from here."
  }
}

# NOTE: every bring-your-own failure below names aws_security_group.this, which
# carries six preconditions, so any one of them satisfies the assertion. That is
# deliberate: the checks were moved to a leaf resource to make the assertions
# discriminating and moved back when it turned out to weaken the gate in the
# apply-deferred path. Gate strength beat assertion precision.
#
# This proves an IGW-only subnet is REJECTED. It cannot prove the
# public-subnet-specific wording survives: that wording is one branch of a
# format() inside byo_bad_subnets, not its own precondition, and expect_failures
# names a resource rather than a condition. Verified by deleting the igw- branch
# — the subnet is still rejected by the same check and this run stays green.
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
    values = { vpc_id = "vpc-somewhere-else" }
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
    error_message = "A NAT instance or inspection/firewall appliance ENI is valid egress and must be accepted — it appears as network_interface_id / instance_id, not nat_gateway_id."
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
    error_message = "A Cloud WAN core-network default route is central egress and must be accepted."
  }
}

# NOTE: this asserts both supplied subnets are validated. It does NOT reproduce
# the unknown-at-plan vpc_id regression, because `variables` blocks can only
# supply known values — a literal vpc_id here is known, so folding
# `var.vpc_id != null` back into local.byo_validate would leave this green.
#
# That regression is covered out-of-band by a root-module harness that builds an
# aws_vpc and feeds its id into the module, which is the only way to produce a
# genuinely unknown value. See the note in README.md under Tests.
run "byo_subnets_are_each_validated" {
  command = plan

  variables {
    create_scanner_vpc = false
    vpc_id             = "vpc-scanner"
    subnet_ids         = ["subnet-a", "subnet-b"]
  }

  assert {
    condition     = length(data.aws_subnet.byo) == 2
    error_message = "Both supplied subnets must be validated; the gate feeding for_each must depend only on the two bool variables, never on vpc_id."
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
    error_message = "A virtual private gateway default route is on-prem egress over VPN or Direct Connect — a standard enterprise topology — and must be accepted."
  }
}

run "byo_subnet_without_enough_free_ips_is_rejected" {
  command = plan

  variables {
    create_scanner_vpc    = false
    vpc_id                = "vpc-scanner"
    subnet_ids            = ["subnet-private-a"]
    max_concurrent_shards = 50
  }

  override_data {
    target = data.aws_subnet.byo["0"]
    values = {
      vpc_id                     = "vpc-scanner"
      available_ip_address_count = 8
    }
  }

  expect_failures = [aws_security_group.this]
}

# An isolated private subnet whose ONLY non-local route is the standard S3
# gateway endpoint. This is the commonest route in an enterprise private subnet
# and says nothing about internet access — accepting it as egress waves through
# a subnet with no internet path at all.
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

# A genuinely public subnet that also carries the S3 gateway endpoint route. The
# prefix-list rule set has_egress = true, which short-circuited the IGW-only
# rejection and let a public subnet through.
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
    error_message = "validate_subnet_egress = false must read no validation data sources, so subnet ids that are unknown until apply do not break for_each."
  }
}
