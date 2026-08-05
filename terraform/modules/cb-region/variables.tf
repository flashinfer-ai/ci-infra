variable "environment" {
  description = "Resource name prefix, e.g. flashinfer"
  type        = string
}

variable "short_code" {
  description = "Compact region code used in resource names, e.g. use1 for us-east-1"
  type        = string
}

variable "runner_key" {
  description = "CB runner kind this region hosts, e.g. gpu-p5-cb. Used in resource names."
  type        = string
}

variable "gpu_type" {
  description = "GPU this region's runners expose, e.g. h100. Used in descriptions."
  type        = string
}

variable "ssm_region" {
  description = "Region holding the GitHub App SSM parameters, read cross-region by the runners"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR for this region's runner VPC. Must not overlap any other runner VPC."
  type        = string
}

variable "azs" {
  description = "AZs to place public subnets in. When null, all AZs available to the account are used."
  type        = list(string)
  default     = null
}

variable "user_data" {
  description = "Base64-encoded user data for the launch template"
  type        = string
}

variable "ami_name_pattern" {
  description = "Name filter for the runner AMI"
  type        = string
  default     = "Deep Learning OSS Nvidia Driver AMI GPU PyTorch 2.* (Ubuntu 22.04) *"
}

variable "ami_owners" {
  description = "Owner account IDs for the runner AMI lookup"
  type        = list(string)
  default     = ["898082745236"]
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB"
  type        = number
  default     = 500
}
