provider "aws" {
  region = var.aws_region

  # Note: In CI, credentials come from OIDC (ci-infra-deploy role)
  # For local development, configure AWS credentials/profile externally

  default_tags {
    tags = {
      Project   = "FlashInfer-CI"
      ManagedBy = "Terraform"
    }
  }
}
