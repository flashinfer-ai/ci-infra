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

variable "enable_h100_us_east_1" {
  description = <<-EOT
    When true, also launch H100 (p5.48xlarge) capacity-block runners in us-east-1.
    The us-west-2 CB scale-up Lambda tries us-west-2 first, then us-east-1.
    Set to false to disable and tear down the us-east-1 substrate.
  EOT
  type        = bool
  default     = true
}
