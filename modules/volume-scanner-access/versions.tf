terraform {
  required_version = ">= 1.3"

  required_providers {
    streamsec = {
      source  = "streamsec-terraform/streamsec"
      version = ">= 1.14.1" # streamsec_aws_scanner_hub_access + streamsec_aws_scanner_access_ack; 1.14.1 keeps the ack when the hub changes
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}
