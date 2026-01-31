provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "FlashInfer-CI"
      ManagedBy = "Terraform"
    }
  }
}
