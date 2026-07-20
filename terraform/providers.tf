provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "FlashInfer-CI"
      ManagedBy = "Terraform"
    }
  }
}

# Secondary region for H100 (p5) capacity-block runners when us-west-2 has no
# p5 capacity. Only used by resources gated on var.enable_h100_us_east_1.
provider "aws" {
  alias  = "use1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "FlashInfer-CI"
      ManagedBy = "Terraform"
    }
  }
}
