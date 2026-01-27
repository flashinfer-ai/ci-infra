output "webhook_endpoint" {
  description = "Webhook endpoint URL for GitHub App configuration"
  value       = module.runners.webhook.endpoint
}

output "webhook_secret" {
  description = "Webhook secret for GitHub App configuration. Use: terraform output -raw webhook_secret"
  value       = var.webhook_secret
  sensitive   = true
}

output "runners_map" {
  description = "Map of runner configurations and their details"
  value       = module.runners.runners_map
}

output "vpc_id" {
  description = "VPC ID where runners are deployed"
  value       = module.base.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs where runners are launched"
  value       = module.base.vpc.private_subnets
}
