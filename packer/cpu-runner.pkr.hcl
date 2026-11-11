# CPU runner AMI: stock Ubuntu 22.04 plus the FlashInfer CI Docker images,
# pulled into the rootless Docker data root that templates/user-data.sh starts.
# Built by .github/workflows/build-runner-ami.yml; see terraform/prebaked-ami.tf.
#
#   packer init packer/cpu-runner.pkr.hcl
#   packer build -var arch=x64 -var subnet_id=subnet-... \
#     -var 'ci_images=["flashinfer/flashinfer-ci-cu130:<tag>"]' \
#     -var images_fingerprint=<sha> packer/cpu-runner.pkr.hcl

packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "arch" {
  description = "Runner architecture: x64 or arm64 (the runner configs' runner_architecture)."
  type        = string
  validation {
    condition     = contains(["x64", "arm64"], var.arch)
    error_message = "The arch must be x64 or arm64."
  }
}

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "subnet_id" {
  description = "Public subnet with internet access (the runners' VPC)."
  type        = string
}

variable "ci_images" {
  description = "Docker images to pre-pull, as repo:tag (from ci/docker-tags.yml)."
  type        = list(string)
}

variable "images_fingerprint" {
  description = "Hash of ci_images, stored as an AMI tag so the workflow can tell whether the current AMI is up to date."
  type        = string
}

variable "root_volume_size_gb" {
  description = "Root volume of the AMI. Launch templates may only grow it (the runners use 500 GiB)."
  type        = number
  default     = 150
}

locals {
  ubuntu_arch   = var.arch == "x64" ? "amd64" : "arm64"
  instance_type = var.arch == "x64" ? "m7i.4xlarge" : "m7g.4xlarge"
  timestamp     = formatdate("YYYYMMDDhhmm", timestamp())
}

source "amazon-ebs" "cpu_runner" {
  ami_name      = "flashinfer-cpu-runner-${var.arch}-${local.timestamp}"
  instance_type = local.instance_type
  region        = var.region
  subnet_id     = var.subnet_id

  associate_public_ip_address               = true
  temporary_security_group_source_public_ip = true

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-${local.ubuntu_arch}-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"] # Canonical
  }
  ssh_username = "ubuntu"

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    iops                  = 16000
    throughput            = 1000
    delete_on_termination = true
  }

  # Large snapshots can take longer than the plugin's default wait.
  aws_polling {
    delay_seconds = 30
    max_attempts  = 240
  }

  tags = {
    Project       = "FlashInfer-CI"
    Purpose       = "flashinfer-cpu-runner"
    Arch          = var.arch
    CiImages      = join(" ", var.ci_images)
    CiImagesHash  = var.images_fingerprint
    Base_AMI_Name = "{{ .SourceAMIName }}"
  }
  snapshot_tags = {
    Project = "FlashInfer-CI"
    Purpose = "flashinfer-cpu-runner"
    Arch    = var.arch
  }
}

build {
  sources = ["source.amazon-ebs.cpu_runner"]

  provisioner "shell" {
    script           = "${path.root}/scripts/prebake-ci-images.sh"
    environment_vars = ["CI_IMAGES=${join(" ", var.ci_images)}"]
    # The script runs as ubuntu (rootless Docker is per-user) and uses sudo.
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} bash {{ .Path }}"
  }

  post-processor "manifest" {
    output     = "manifest-${var.arch}.json"
    strip_path = true
  }
}
