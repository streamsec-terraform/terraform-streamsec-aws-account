terraform {
  # Must not be lower than any module this example calls. modules/volume-scanner
  # requires >= 1.3, and Terraform aggregates required_version across the whole
  # configuration — so ">= 1.0" here promised a floor the example cannot honour
  # and sent anyone on 1.0-1.2 into a failure at init.
  required_version = ">= 1.3"

  required_providers {
    streamsec = {
      source  = "streamsec-terraform/streamsec"
      version = ">= 1.12"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}
