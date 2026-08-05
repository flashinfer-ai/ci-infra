# Capacity-block launch substrate for one region.
#
# Holds only what has to exist in the region the instances boot in: VPC, public
# subnets, security group, AMI lookup, instance role/profile and launch template.
# The SQS queue, EventBridge routing and cb-scale-up Lambda stay in the home
# region (see ../../cb-runners.tf) and launch here via EXTRA_LAUNCH_TARGETS.
#
# The caller passes an aliased provider, so every resource here lands in that
# region without this module hardcoding one.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.21"
    }
  }
}

data "aws_region" "current" {}

# Only consulted when var.azs is null. AZ availability differs per account in
# some regions (us-west-1 typically exposes two of its three AZs), so letting
# the provider report them avoids hardcoding a list that fails to apply.
data "aws_availability_zones" "available" {
  count = var.azs == null ? 1 : 0

  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = var.azs != null ? var.azs : data.aws_availability_zones.available[0].names

  # One /24 per AZ starting at .101, matching the home-region VPC layout.
  public_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, 101 + i)]

  runner_name = "${var.environment}-cb-runner-${var.short_code}"
  lt_name     = "${var.environment}-${var.runner_key}-${var.short_code}"

  common_tags = {
    Environment = var.environment
    Project     = "FlashInfer"
    ManagedBy   = "Terraform"
  }
}

# --- Networking (public subnets only; CB runners use public IPs for egress) ---
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = "${var.environment}-vpc-${var.short_code}"
  cidr = var.vpc_cidr

  azs            = local.azs
  public_subnets = local.public_subnets

  enable_dns_hostnames    = true
  enable_nat_gateway      = false # public subnets only -> egress via IGW, no NAT cost
  map_public_ip_on_launch = true

  tags = local.common_tags
}

data "aws_ami" "runner" {
  most_recent = true
  owners      = var.ami_owners

  filter {
    name   = "name"
    values = [var.ami_name_pattern]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_security_group" "cb_runner" {
  name        = "${local.runner_name}-sg"
  description = "Security group for ${data.aws_region.current.region} ${upper(var.gpu_type)} CB runner instances"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.runner_name}-sg"
  })
}

# --- Instance role/profile ---
# Per-region role so each region's runners only get the ARNs they need. IAM is
# global, so the instance profile is usable from any region.
resource "aws_iam_role" "cb_runner" {
  name = local.runner_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_instance_profile" "cb_runner" {
  name = local.runner_name
  role = aws_iam_role.cb_runner.name
}

resource "aws_iam_role_policy" "cb_runner" {
  name = "${local.runner_name}-policy"
  role = aws_iam_role.cb_runner.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GitHub App credentials live in the home region's SSM; read them cross-region.
        Sid    = "SSMParametersHomeRegion"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:${var.ssm_region}:*:parameter/github-action-runners/${var.environment}/*"
      },
      {
        Sid    = "SSMSessionManager"
        Effect = "Allow"
        Action = [
          "ssm:DescribeInstanceInformation",
          "ssm:UpdateInstanceInformation",
          "ssmmessages:*",
          "ec2messages:*"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        # Instance tags itself in its own region.
        Sid    = "EC2TagSelf"
        Effect = "Allow"
        Action = [
          "ec2:CreateTags"
        ]
        Resource = "arn:aws:ec2:${data.aws_region.current.region}:*:instance/*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/ManagedBy" = "Terraform"
          }
        }
      }
    ]
  })
}

# No instance_type here: the cb-scale-up Lambda sets it at RunInstances time so
# one template can serve whatever the active Capacity Block holds.
resource "aws_launch_template" "cb_runner" {
  name        = "${local.lt_name}-launch-template"
  description = "Launch template for ${data.aws_region.current.region} ${upper(var.gpu_type)} CB runners"

  image_id = data.aws_ami.runner.id

  iam_instance_profile {
    name = aws_iam_instance_profile.cb_runner.name
  }

  vpc_security_group_ids = [aws_security_group.cb_runner.id]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  user_data = var.user_data

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${local.lt_name}-action-runner"
    })
  }

  tags = merge(local.common_tags, {
    Name = "${local.lt_name}-launch-template"
  })
}
