terraform {
  # 1.3 for startswith(), used by the bring-your-own-subnet egress check.
  # Lifecycle preconditions (1.2) set the earlier floor; startswith raised it.
  required_version = ">= 1.3"

  required_providers {
    streamsec = {
      source = "streamsec-terraform/streamsec"
      # Only streamsec_host and streamsec_aws_account are used, both present since
      # 1.7. Raise this to whatever release ships streamsec_aws_scanner_ack at the
      # same time as uncommenting ack.tf — requiring it now would break consumers
      # who pin an older streamsec elsewhere in their configuration, for a
      # resource this module does not declare.
      version = ">= 1.7"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}
