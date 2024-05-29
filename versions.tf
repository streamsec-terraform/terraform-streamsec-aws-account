terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "streamsec-terraform/streamsec"
      version = ">= 1.2"
    }
  }
}