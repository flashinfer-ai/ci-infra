# Secondary-region (us-east-1) H100 capacity-block launch substrate.
#
# All resources here are gated on var.enable_h100_us_east_1 (default false), so
# with the flag off this file creates nothing and `terraform plan` is a no-op.
#
# Only the *launch* substrate lives here (VPC, subnets, SG, AMI, launch template,
# instance profile). The SQS queue, EventBridge routing and the cb-scale-up
# Lambda stay in us-west-2 (see cb-runners.tf); the Lambda launches into this
# region via the EXTRA_LAUNCH_TARGETS env var when the flag is on.

locals {
  use1_enabled = var.enable_h100_us_east_1 ? 1 : 0
}

# --- Networking (public subnets only; CB runners use public IPs for egress) ---
module "vpc_use1" {
  count = local.use1_enabled

  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  providers = { aws = aws.use1 }

  name = "${local.environment}-vpc-use1"
  cidr = "10.1.0.0/16"

  # p5 capacity blocks in us-east-1 are offered across these AZs.
  azs            = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d", "us-east-1f"]
  public_subnets = ["10.1.101.0/24", "10.1.102.0/24", "10.1.103.0/24", "10.1.104.0/24", "10.1.105.0/24"]

  enable_dns_hostnames    = true
  enable_nat_gateway      = false # public subnets only -> egress via IGW, no NAT cost
  map_public_ip_on_launch = true

  tags = {
    Project     = "FlashInfer"
    Environment = local.environment
    ManagedBy   = "Terraform"
  }
}

data "aws_ami" "deep_learning_use1" {
  count = local.use1_enabled

  provider    = aws.use1
  most_recent = true
  owners      = ["898082745236"]

  filter {
    name   = "name"
    values = ["Deep Learning OSS Nvidia Driver AMI GPU PyTorch 2.* (Ubuntu 22.04) *"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_security_group" "cb_runner_use1" {
  count = local.use1_enabled

  provider    = aws.use1
  name        = "${local.environment}-cb-runner-use1-sg"
  description = "Security group for us-east-1 H100 CB runner instances"
  vpc_id      = module.vpc_use1[0].vpc_id

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name        = "${local.environment}-cb-runner-use1-sg"
    Environment = local.environment
    Project     = "FlashInfer"
    ManagedBy   = "Terraform"
  }
}

# --- Instance role/profile for us-east-1 runners ---
# Separate from the us-west-2 cb_runner role so existing IAM is untouched.
# IAM is global; the instance profile is usable from us-east-1.
resource "aws_iam_role" "cb_runner_use1" {
  count = local.use1_enabled

  name = "${local.environment}-cb-runner-use1"

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

  tags = {
    Environment = local.environment
    Project     = "FlashInfer"
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_instance_profile" "cb_runner_use1" {
  count = local.use1_enabled

  name = "${local.environment}-cb-runner-use1"
  role = aws_iam_role.cb_runner_use1[0].name
}

resource "aws_iam_role_policy" "cb_runner_use1" {
  count = local.use1_enabled

  name = "${local.environment}-cb-runner-use1-policy"
  role = aws_iam_role.cb_runner_use1[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GitHub App credentials live in us-west-2 SSM; read them cross-region.
        Sid    = "SSMParametersHomeRegion"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/github-action-runners/${local.environment}/*"
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
        # Instance tags itself in its own region (us-east-1).
        Sid    = "EC2TagSelf"
        Effect = "Allow"
        Action = [
          "ec2:CreateTags"
        ]
        Resource = "arn:aws:ec2:us-east-1:*:instance/*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/ManagedBy" = "Terraform"
          }
        }
      }
    ]
  })
}

resource "aws_launch_template" "cb_runner_use1" {
  count = local.use1_enabled

  provider    = aws.use1
  name        = "${local.environment}-gpu-p5-cb-use1-launch-template"
  description = "Launch template for us-east-1 H100 (p5) CB runners"

  image_id = data.aws_ami.deep_learning_use1[0].id

  iam_instance_profile {
    name = aws_iam_instance_profile.cb_runner_use1[0].name
  }

  vpc_security_group_ids = [aws_security_group.cb_runner_use1[0].id]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 500
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

  user_data = base64encode(templatefile("${path.module}/templates/user-data-multi-runner-xregion.sh", {
    ssm_region           = var.aws_region # GitHub App creds live in us-west-2
    environment          = local.environment
    instance_type        = "p5.48xlarge"
    gpu_type             = "h100"
    ssm_config_path      = "/github-action-runners/${local.environment}/gpu-p5-cb/runners/config"
    github_app_id_param  = "/github-action-runners/${local.environment}/app/github_app_id"
    github_app_key_param = "/github-action-runners/${local.environment}/app/github_app_key_base64"
    org_name             = "flashinfer-ai"
    runner_group         = "Default"
    labels_base          = "self-hosted,linux,x64,gpu,nvidia,h100,hopper,capacity-block"
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${local.environment}-gpu-p5-cb-use1-action-runner"
      Environment = local.environment
      Project     = "FlashInfer"
      ManagedBy   = "Terraform"
    }
  }

  tags = {
    Name        = "${local.environment}-gpu-p5-cb-use1-launch-template"
    Environment = local.environment
    Project     = "FlashInfer"
    ManagedBy   = "Terraform"
  }
}
