# Runner AMIs with the FlashInfer CI Docker images already pulled.
#
# A runner launched for a job pulls flashinfer/flashinfer-ci-cu{129,130,134}
# (about 8 GB of gzip layers each) before the job can start. Measured from
# Actions logs, that takes 4-6 minutes on the 64-core CPU runners (AOT builds)
# and 4-8 minutes (median 6) on the g4dn/g5 GPU runners, mostly serial layer
# extraction. packer/runner.pkr.hcl bakes the images into the Docker store of
# the AMI each runner type already uses, and .github/workflows/build-runner-ami.yml
# rebuilds those AMIs whenever ci/docker-tags.yml in flashinfer-ai/flashinfer
# changes.
#
# The launch templates read the AMI from the SSM parameters below at launch time
# (resolve:ssm:), so a new AMI goes live when the workflow overwrites the
# parameter, with no Terraform apply. Terraform creates each parameter pointing
# at the same stock AMI the runners used before, and never resets it. If the
# parameter is left alone, or the images in the AMI are stale, ci/bash.sh still
# pulls whatever is missing, so a missing or old AMI only costs time.
#
# Not covered: the capacity-block and p4d nodes (cb-runners.tf, p4d-runners.tf)
# keep Docker on instance-store NVMe, which an AMI cannot pre-fill, and they are
# long-lived, so their jobs already find the image cached. g7e runs few,
# hours-long jobs on a different base AMI (Ubuntu 24.04 DLAMI).

locals {
  # Pre-baked AMI flavors (the SSM parameter suffix), with the base AMI each
  # starts from. Keep in sync with packer/runner.pkr.hcl.
  prebaked_amis = {
    "cpu-x64" = {
      owner        = "099720109477" # Canonical
      name         = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      architecture = "x86_64"
    }
    "cpu-arm64" = {
      owner        = "099720109477"
      name         = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"
      architecture = "arm64"
    }
    "gpu-x64" = {
      owner        = "898082745236" # AWS Deep Learning AMI
      name         = "Deep Learning OSS Nvidia Driver AMI GPU PyTorch 2.* (Ubuntu 22.04) *"
      architecture = "x86_64"
    }
  }

  # Runner config (file name in templates/runner-configs without .yaml) -> the
  # pre-baked AMI it launches from. Each base AMI above must match the config's
  # own ami filter, which stays in the YAML as documentation.
  prebaked_ami_runner_configs = {
    "cpu-x64-ondemand"   = "cpu-x64"
    "cpu-arm64-ondemand" = "cpu-arm64"
    "gpu-g4dn-ondemand"  = "gpu-x64"
    "gpu-g5-ondemand"    = "gpu-x64"
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  # Built from plan-time values rather than aws_ssm_parameter.runner_ami[*].arn:
  # the runner module derives resource counts from this ARN, so it must be known
  # at plan time, and the parameter's arn is not until it exists. Its name is a
  # configured value, and referencing it still orders the parameter before the
  # launch templates that resolve it.
  prebaked_ami_ssm_arns = {
    for name, param in aws_ssm_parameter.runner_ami :
    name => "arn:${data.aws_partition.current.partition}:ssm:${local.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${param.name}"
  }
}

data "aws_ami" "prebaked_base" {
  for_each    = local.prebaked_amis
  most_recent = true
  owners      = [each.value.owner]

  filter {
    name   = "name"
    values = [each.value.name]
  }
  filter {
    name   = "architecture"
    values = [each.value.architecture]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_ssm_parameter" "runner_ami" {
  for_each    = local.prebaked_amis
  name        = "/flashinfer/runners/ami/${each.key}"
  description = "AMI for the ${each.key} runners; written by .github/workflows/build-runner-ami.yml"
  type        = "String"
  data_type   = "aws:ec2:image"
  value       = data.aws_ami.prebaked_base[each.key].id

  lifecycle {
    # Owned by the AMI build workflow after creation.
    ignore_changes = [value]
  }
}
