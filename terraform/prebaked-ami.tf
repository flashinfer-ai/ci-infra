# Runner AMIs with the FlashInfer CI Docker images already pulled.
#
# The PR "AOT Build Import" jobs pull flashinfer/flashinfer-ci-cu{129,130,134}
# (about 8 GB of gzip layers each) on every fresh runner, which takes 4-6
# minutes, mostly serial layer extraction. packer/cpu-runner.pkr.hcl bakes those
# images into the rootless Docker data root of an otherwise stock Ubuntu 22.04
# AMI, and .github/workflows/build-runner-ami.yml rebuilds it whenever
# ci/docker-tags.yml in flashinfer-ai/flashinfer changes.
#
# The launch templates read the AMI from the SSM parameters below at launch time
# (resolve:ssm:), so a new AMI goes live when the workflow overwrites the
# parameter, with no Terraform apply. Terraform creates each parameter pointing
# at the same stock Canonical AMI the runners used before, and never resets it.
# If the parameter is left alone, or the images in the AMI are stale, ci/bash.sh
# still pulls whatever is missing, so a missing or old AMI only costs time.

locals {
  # Runner configs (file names in templates/runner-configs without .yaml) that
  # launch from the pre-baked AMI of their architecture.
  prebaked_ami_runner_configs = toset([
    "cpu-x64-ondemand",
    "cpu-arm64-ondemand",
  ])

  # runner_architecture -> Canonical AMI name architecture
  prebaked_ami_arches = {
    x64   = "amd64"
    arm64 = "arm64"
  }
}

data "aws_ami" "ubuntu_jammy" {
  for_each    = local.prebaked_ami_arches
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-${each.value}-server-*"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_ssm_parameter" "cpu_runner_ami" {
  for_each    = local.prebaked_ami_arches
  name        = "/flashinfer/runners/ami/cpu-${each.key}"
  description = "AMI for the ${each.key} CPU runners; written by .github/workflows/build-runner-ami.yml"
  type        = "String"
  data_type   = "aws:ec2:image"
  value       = data.aws_ami.ubuntu_jammy[each.key].id

  lifecycle {
    # Owned by the AMI build workflow after creation.
    ignore_changes = [value]
  }
}
