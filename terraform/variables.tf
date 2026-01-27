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
