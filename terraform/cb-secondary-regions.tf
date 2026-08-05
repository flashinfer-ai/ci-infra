# Secondary-region capacity-block launch substrates.
#
# Capacity Blocks are only offered in some regions at a time and expire, so the
# H100/B200 runners have to be launchable wherever the current reservation lives.
# Each region here gets the launch substrate from ./modules/cb-region (VPC, SG,
# AMI, instance role, launch template). The SQS queue, EventBridge routing and
# the cb-scale-up Lambda stay in var.aws_region (see cb-runners.tf) and launch
# into these regions via the Lambda's EXTRA_LAUNCH_TARGETS.
#
# To add a region:
#   1. add an entry to var.cb_secondary_regions in variables.tf
#   2. add a provider alias in providers.tf
#   3. copy one module block below and add it to local.cb_secondary_substrates
# Steps 2 and 3 are unavoidable because Terraform cannot for_each providers.
#
# Disabling a region (enabled = false) destroys its substrate and drops it from
# the Lambda's fallback list; nothing else in the config needs to change.

locals {
  cb_region_use1 = var.cb_secondary_regions["us-east-1"]
  cb_region_usw1 = var.cb_secondary_regions["us-west-1"]

  # User data is region-independent: the xregion template reads the instance's
  # own region from IMDS and the GitHub App credentials from the home region's
  # SSM, so one rendering per CB runner kind serves every secondary region.
  cb_xregion_user_data = {
    for key, cfg in local.cb_runners : key => base64encode(templatefile(
      "${path.module}/templates/user-data-multi-runner-xregion.sh",
      {
        ssm_region           = var.aws_region
        environment          = local.environment
        instance_type        = cfg.instance_type
        gpu_type             = cfg.gpu_type
        ssm_config_path      = "/github-action-runners/${local.environment}/${key}/runners/config"
        github_app_id_param  = "/github-action-runners/${local.environment}/app/github_app_id"
        github_app_key_param = "/github-action-runners/${local.environment}/app/github_app_key_base64"
        org_name             = "flashinfer-ai"
        runner_group         = "Default"
        labels_base          = cfg.labels_base
      }
    ))
  }
}

module "cb_region_use1" {
  source = "./modules/cb-region"
  count  = local.cb_region_use1.enabled ? 1 : 0

  providers = { aws = aws.use1 }

  environment = local.environment
  ssm_region  = var.aws_region
  short_code  = local.cb_region_use1.short_code
  runner_key  = local.cb_region_use1.runner_key
  gpu_type    = local.cb_runners[local.cb_region_use1.runner_key].gpu_type
  vpc_cidr    = local.cb_region_use1.vpc_cidr
  azs         = local.cb_region_use1.azs
  user_data   = local.cb_xregion_user_data[local.cb_region_use1.runner_key]
}

module "cb_region_usw1" {
  source = "./modules/cb-region"
  count  = local.cb_region_usw1.enabled ? 1 : 0

  providers = { aws = aws.usw1 }

  environment = local.environment
  ssm_region  = var.aws_region
  short_code  = local.cb_region_usw1.short_code
  runner_key  = local.cb_region_usw1.runner_key
  gpu_type    = local.cb_runners[local.cb_region_usw1.runner_key].gpu_type
  vpc_cidr    = local.cb_region_usw1.vpc_cidr
  azs         = local.cb_region_usw1.azs
  user_data   = local.cb_xregion_user_data[local.cb_region_usw1.runner_key]
}

locals {
  # Flattened view of the substrates that exist, in Lambda fallback order. A
  # disabled region has zero module instances and so contributes nothing. The
  # region comes from the module itself, so it cannot disagree with the alias.
  cb_secondary_substrates = concat(
    [for m in module.cb_region_use1 : merge(m, { runner_key = local.cb_region_use1.runner_key })],
    [for m in module.cb_region_usw1 : merge(m, { runner_key = local.cb_region_usw1.runner_key })],
  )

  # Fallback launch targets per CB runner kind, in the shape the Lambda's
  # EXTRA_LAUNCH_TARGETS expects.
  cb_secondary_targets = {
    for key in keys(local.cb_runners) : key => [
      for s in local.cb_secondary_substrates : {
        region          = s.region
        launch_template = s.launch_template_name
        subnet_ids      = s.public_subnet_ids
      } if s.runner_key == key
    ]
  }

  # Instance roles the Lambda needs iam:PassRole on to launch outside the home region.
  cb_secondary_runner_role_arns = [for s in local.cb_secondary_substrates : s.runner_role_arn]
}

# The us-east-1 substrate predates ./modules/cb-region and was declared inline in
# cb-runners-us-east-1.tf. These keep the existing objects instead of destroying
# and recreating them; they can be dropped once the move has been applied.
moved {
  from = module.vpc_use1[0]
  to   = module.cb_region_use1[0].module.vpc
}

moved {
  from = aws_security_group.cb_runner_use1[0]
  to   = module.cb_region_use1[0].aws_security_group.cb_runner
}

moved {
  from = aws_iam_role.cb_runner_use1[0]
  to   = module.cb_region_use1[0].aws_iam_role.cb_runner
}

moved {
  from = aws_iam_instance_profile.cb_runner_use1[0]
  to   = module.cb_region_use1[0].aws_iam_instance_profile.cb_runner
}

moved {
  from = aws_iam_role_policy.cb_runner_use1[0]
  to   = module.cb_region_use1[0].aws_iam_role_policy.cb_runner
}

moved {
  from = aws_launch_template.cb_runner_use1[0]
  to   = module.cb_region_use1[0].aws_launch_template.cb_runner
}
