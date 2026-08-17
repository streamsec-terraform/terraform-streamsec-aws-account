mock_provider "aws" {
  mock_data "aws_region" { defaults = { region = "us-east-1" } }
  mock_data "aws_caller_identity" { defaults = { account_id = "111111111111" } }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_ecs_clusters" { defaults = { cluster_arns = [] } }
  mock_data "aws_subnet" {
    defaults = { id = "subnet-m", vpc_id = "vpc-m", cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" }
  }
  mock_data "aws_route_tables" { defaults = { ids = ["rtb-x"] } }
  mock_data "aws_route_table" {
    defaults = { routes = [{
      cidr_block  = "0.0.0.0/0", destination_prefix_list_id = "", nat_gateway_id = "nat-x",
      gateway_id  = "", transit_gateway_id = "", vpc_endpoint_id = "", network_interface_id = "",
      instance_id = "", core_network_arn = "", local_gateway_id = ""
    }] }
  }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::111111111111:role/m" } }
}
mock_provider "streamsec" {
  mock_data "streamsec_host" { defaults = { url = "https://acme.streamsec.io" } }
  mock_data "streamsec_aws_account" { defaults = { cloud_account_id = "111111111111", streamsec_collection_token = "t" } }
}
mock_provider "archive" {}
mock_provider "random" {}

run "byo_with_unknown_subnet_ids_but_known_length_plans" {
  command = plan
}
