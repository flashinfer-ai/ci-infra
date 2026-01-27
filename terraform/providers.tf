provider "aws" {
  region = var.aws_region

  assume_role {
    role_arn     = "arn:aws:iam::339333478894:role/Administrator"
    session_name = "flashinfer-terraform"
  }

  default_tags {
    tags = {
      Project   = "FlashInfer-CI"
      ManagedBy = "Terraform"
    }
  }
}
