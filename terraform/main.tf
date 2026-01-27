# FlashInfer CI Infrastructure
# Uses terraform-aws-github-runner as a submodule (unmodified upstream)
# Capacity Block runners are handled by custom infrastructure (see cb-runners.tf)

locals {
  environment = "flashinfer"
  aws_region  = var.aws_region

  # Load runner configurations from YAML files
  # Excludes CB configs (gpu-p5-cb, gpu-p6-cb) - those are handled separately
  multi_runner_config_files = {
    for c in fileset("${path.module}/templates/runner-configs", "*.yaml") :
    trimsuffix(c, ".yaml") => yamldecode(file("${path.module}/templates/runner-configs/${c}"))
    if !can(regex("-cb\\.yaml$", c))  # Exclude CB configs
  }

  # Inject dynamic values (VPC, subnets) into configurations
  multi_runner_config = {
    for k, v in local.multi_runner_config_files :
    k => merge(
      v,
      {
        runner_config = merge(
          v.runner_config,
          {
            # Always inject VPC and subnet
            subnet_ids = module.vpc.private_subnets
            vpc_id     = module.vpc.vpc_id
          }
        )
      }
    )
  }
}

# Main runners module - handles spot and on-demand runners
# CB runners are handled separately in cb-runners.tf
module "runners" {
  source = "../3rdparty/terraform-aws-github-runner/modules/multi-runner"

  multi_runner_config = local.multi_runner_config

  aws_region = local.aws_region
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
  prefix     = local.environment

  github_app = {
    key_base64     = var.github_app_key_base64
    id             = var.github_app_id
    webhook_secret = var.webhook_secret
  }

  # Lambda zips - download these first using the lambdas-download module
  webhook_lambda_zip                = "${path.module}/lambdas-download/webhook.zip"
  runner_binaries_syncer_lambda_zip = "${path.module}/lambdas-download/runner-binaries-syncer.zip"
  runners_lambda_zip                = "${path.module}/lambdas-download/runners.zip"

  # Increase lambda timeouts for spot failover
  runners_scale_up_lambda_timeout   = 60
  runners_scale_down_lambda_timeout = 60

  # Enable tracing for debugging
  tracing_config = {
    mode                  = "Active"
    capture_error         = true
    capture_http_requests = true
  }

  # Enable spot termination watcher
  instance_termination_watcher = {
    enable = true
    zip    = "${path.module}/lambdas-download/termination-watcher.zip"
  }

  # Enable metrics for monitoring
  metrics = {
    enable = true
    metric = {
      enable_spot_termination_warning = true
      enable_github_app_rate_limit    = true
    }
  }

  # EventBridge mode (recommended)
  eventbridge = {
    enable        = true
    accept_events = ["workflow_job"]
  }

  # Logging level (use "info" for production)
  log_level = "debug"

  tags = {
    Project     = "FlashInfer"
    Environment = local.environment
    ManagedBy   = "Terraform"
  }
}

# Auto-configure GitHub App webhook
module "webhook_github_app" {
  source     = "../3rdparty/terraform-aws-github-runner/modules/webhook-github-app"
  depends_on = [module.runners]

  github_app = {
    key_base64     = var.github_app_key_base64
    id             = var.github_app_id
    webhook_secret = var.webhook_secret
  }
  webhook_endpoint = module.runners.webhook.endpoint
}
