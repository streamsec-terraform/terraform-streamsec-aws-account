terraform {
  # 1.3 for startswith(), used by the bring-your-own-subnet egress check.
  # Lifecycle preconditions (1.2) — the Terraform-native replacement for the
  # CloudFormation NetworkPrecheck Lambda — set the earlier floor; startswith
  # raised it.
  required_version = ">= 1.3"

  required_providers {
    streamsec = {
      source  = "streamsec-terraform/streamsec"
      version = ">= 1.13"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}
