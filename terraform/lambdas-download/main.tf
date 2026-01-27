# Download Lambda packages from terraform-aws-github-runner releases
#
# Usage:
#   cd lambdas-download
#   terraform init
#   terraform apply -var="module_version=7.3.0"

variable "module_version" {
  description = "Version of terraform-aws-github-runner to download lambdas from"
  type        = string
  default     = "7.3.0"
}

locals {
  lambda_files = [
    "webhook.zip",
    "runners.zip",
    "runner-binaries-syncer.zip",
    "termination-watcher.zip"
  ]
}

# Download Lambda zips from GitHub releases
resource "null_resource" "download_lambdas" {
  for_each = toset(local.lambda_files)

  triggers = {
    version = var.module_version
  }

  provisioner "local-exec" {
    command = <<-EOT
      curl -L -o ${each.value} \
        "https://github.com/github-aws-runners/terraform-aws-github-runner/releases/download/v${var.module_version}/${each.value}"
    EOT
  }
}

output "lambda_files" {
  description = "Downloaded Lambda files"
  value       = local.lambda_files
}

output "version" {
  description = "Version downloaded"
  value       = var.module_version
}
