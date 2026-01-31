terraform {
  required_version = ">= 1.3.0"

  backend "s3" {
    bucket = "flashinfer-ci-terraform-state"
    key    = "ci-infra/terraform.tfstate"
    region = "us-west-2"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.21"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}
