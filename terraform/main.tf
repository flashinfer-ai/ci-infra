locals {
  environment = "flashinfer"
  aws_region  = var.aws_region

  multi_runner_config_files = {
    for c in fileset("${path.module}/templates/runner-configs", "*.yaml") :
    trimsuffix(c, ".yaml") => yamldecode(file("${path.module}/templates/runner-configs/${c}"))
    if !can(regex("-cb\\.yaml$", c))
  }

  multi_runner_config = {
    for k, v in local.multi_runner_config_files :
    k => merge(
      v,
      {
        runner_config = merge(
          v.runner_config,
          {
            subnet_ids = module.vpc.public_subnets
            vpc_id     = module.vpc.vpc_id
          }
        )
      }
    )
  }
}

module "runners" {
  source = "../3rdparty/terraform-aws-github-runner/modules/multi-runner"

  multi_runner_config = local.multi_runner_config

  aws_region = local.aws_region
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets
  prefix     = local.environment

  github_app = {
    key_base64     = var.github_app_key_base64
    id             = var.github_app_id
    webhook_secret = var.webhook_secret
  }

  webhook_lambda_zip                = "${path.module}/lambdas-download/webhook.zip"
  runner_binaries_syncer_lambda_zip = "${path.module}/lambdas-download/runner-binaries-syncer.zip"
  runners_lambda_zip                = "${path.module}/lambdas-download/runners.zip"

  runners_scale_up_lambda_timeout   = 60
  runners_scale_down_lambda_timeout = 60

  tracing_config = {
    mode                  = "Active"
    capture_error         = true
    capture_http_requests = true
  }

  instance_termination_watcher = {
    enable = true
    zip    = "${path.module}/lambdas-download/termination-watcher.zip"
  }

  metrics = {
    enable = true
    metric = {
      enable_spot_termination_warning = true
      enable_github_app_rate_limit    = true
    }
  }

  eventbridge = {
    enable        = true
    accept_events = ["workflow_job"]
  }

  log_level = "debug"

  tags = {
    Project     = "FlashInfer"
    Environment = local.environment
    ManagedBy   = "Terraform"
  }
}

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
