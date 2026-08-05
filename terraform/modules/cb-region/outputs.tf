output "region" {
  description = "Region this substrate was created in"
  value       = data.aws_region.current.region
}

output "launch_template_name" {
  description = "Launch template the cb-scale-up Lambda should use for this region"
  value       = aws_launch_template.cb_runner.name
}

output "public_subnet_ids" {
  description = "Public subnets the Lambda picks from, one per AZ"
  value       = module.vpc.public_subnets
}

output "runner_role_arn" {
  description = "Instance role ARN the Lambda needs iam:PassRole on"
  value       = aws_iam_role.cb_runner.arn
}
