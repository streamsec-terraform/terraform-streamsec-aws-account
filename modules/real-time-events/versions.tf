terraform {
  required_version = ">= 1.0"

  required_providers {
    streamsec = {
      source  = "streamsec-terraform/streamsec"
      version = ">= 1.7"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.11"
    }
  }
}
