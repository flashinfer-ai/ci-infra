provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "FlashInfer-CI"
      ManagedBy = "Terraform"
    }
  }
}

# Secondary regions for capacity-block runners, used when the home region has no
# active Capacity Block. Terraform cannot for_each provider configurations, so
# each region in var.cb_secondary_regions needs an alias declared here; the
# matching substrate lives in cb-secondary-regions.tf.
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

provider "aws" {
  alias  = "usw1"
  region = "us-west-1"

  default_tags {
    tags = {
      Project   = "FlashInfer-CI"
      ManagedBy = "Terraform"
    }
  }
}
