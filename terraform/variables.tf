variable "aws_region" {
  description = "AWS region to deploy to"
  type        = string
  default     = "us-west-2"
}

variable "github_app_id" {
  description = "GitHub App ID"
  type        = string
  sensitive   = true
}

variable "github_app_key_base64" {
  description = "GitHub App private key (base64 encoded). Generate with: base64 -i your-app.private-key.pem"
  type        = string
  sensitive   = true
}

variable "webhook_secret" {
  description = "Webhook secret for GitHub App. Generate with: openssl rand -hex 32"
  type        = string
  sensitive   = true
}

variable "cb_secondary_regions" {
  description = <<-EOT
    Regions besides var.aws_region that can host capacity-block runners, keyed by
    region. The cb-scale-up Lambda tries var.aws_region first, then these in key
    order, launching into whichever has an active Capacity Block. Capacity Blocks
    are only offered in some regions at a time, so this is how a new reservation
    in a new region gets picked up.

    Adding a region needs three edits (Terraform cannot for_each providers):
    an entry here, a provider alias in providers.tf, and a module block plus a
    registry entry in cb-secondary-regions.tf.

    Fields:
      enabled    - create the substrate and offer the region to the Lambda
      short_code - compact code used in resource names, e.g. use1 for us-east-1
      vpc_cidr   - /16 for this region's runner VPC; must not overlap another
      runner_key - which local.cb_runners entry this region hosts
      azs        - AZs for the public subnets; null discovers the account's AZs
  EOT

  type = map(object({
    enabled    = bool
    short_code = string
    vpc_cidr   = string
    runner_key = optional(string, "gpu-p5-cb")
    azs        = optional(list(string))
  }))

  default = {
    "us-east-1" = {
      enabled    = true
      short_code = "use1"
      vpc_cidr   = "10.1.0.0/16"
      # us-east-1e does not offer p5, so it is left out.
      azs = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d", "us-east-1f"]
    }
    "us-west-1" = {
      enabled    = true
      short_code = "usw1"
      vpc_cidr   = "10.2.0.0/16"
      # us-west-1 exposes a different AZ subset per account, so discover them.
      azs = null
    }
  }

  validation {
    condition = alltrue([
      for r in ["us-east-1", "us-west-1"] : contains(keys(var.cb_secondary_regions), r)
    ])
    error_message = "cb_secondary_regions must keep an entry for every region with a provider alias (us-east-1, us-west-1). Set enabled = false to turn one off instead of removing it."
  }
}
