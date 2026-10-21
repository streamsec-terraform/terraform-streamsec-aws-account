terraform {
  required_version = ">= 1.3"

  required_providers {
    streamsec = {
      source  = "streamsec-terraform/streamsec"
      version = ">= 1.14.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}
