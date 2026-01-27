# Capacity Block Runners Infrastructure
# 
# This file sets up custom infrastructure for Capacity Block (CB) based runners
# (p5.48xlarge for H100, p6-b200.48xlarge for B200).
# 
# This is separate from the upstream terraform-aws-github-runner module to avoid
# patching upstream code. The upstream module handles spot/on-demand runners,
# while this handles CB runners.

locals {
  cb_runners = {
    "gpu-p6-cb" = {
      instance_type = "p6-b200.48xlarge"
      labels        = ["sm100", "b200", "blackwell"]
      description   = "B200 GPU (Blackwell)"
    }
    "gpu-p5-cb" = {
      instance_type = "p5.48xlarge"
      labels        = ["sm90", "h100", "hopper"]
      description   = "H100 GPU (Hopper)"
    }
  }
}

# =============================================================================
# SQS Queues for CB Jobs
# =============================================================================

resource "aws_sqs_queue" "cb_builds" {
  for_each = local.cb_runners

  name                       = "${local.environment}-${each.key}-queued-builds"
  delay_seconds              = 300  # 5 min delay for CB to become active
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400  # 24 hours

  tags = {
    Name        = "${local.environment}-${each.key}-queued-builds"
    Environment = local.environment
    Project     = "FlashInfer"
    ManagedBy   = "Terraform"
  }
}

resource "aws_sqs_queue" "cb_builds_dlq" {
  for_each = local.cb_runners

  name                      = "${local.environment}-${each.key}-queued-builds-dlq"
  message_retention_seconds = 604800  # 7 days

  tags = {
    Name        = "${local.environment}-${each.key}-queued-builds-dlq"
    Environment = local.environment
    Project     = "FlashInfer"
    ManagedBy   = "Terraform"
  }
}

# =============================================================================
# EventBridge Rules - Route CB-labeled jobs to our queues
# =============================================================================

resource "aws_cloudwatch_event_rule" "cb_workflow_job" {
  for_each = local.cb_runners

  name           = "${local.environment}-${each.key}-workflow-job"
  description    = "Route ${each.value.description} jobs to CB queue"
  event_bus_name = module.runners.eventbridge.event_bus.name

  event_pattern = jsonencode({
    source      = ["github-runners.${local.environment}"]
    detail-type = ["workflow_job"]
    detail = {
      event = ["queued"]
      labels = [for label in each.value.labels : { prefix = label }]
    }
  })

  tags = {
    Environment = local.environment
    Project     = "FlashInfer"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_event_target" "cb_sqs" {
  for_each = local.cb_runners

  rule           = aws_cloudwatch_event_rule.cb_workflow_job[each.key].name
  event_bus_name = module.runners.eventbridge.event_bus.name
  target_id      = "${each.key}-sqs"
  arn            = aws_sqs_queue.cb_builds[each.key].arn

  input_transformer {
    input_paths = {
      id              = "$.detail.id"
      repositoryName  = "$.detail.repositoryName"
      repositoryOwner = "$.detail.repositoryOwner"
      installationId  = "$.detail.installationId"
    }
    input_template = <<EOF
{
  "id": <id>,
  "repositoryName": <repositoryName>,
  "repositoryOwner": <repositoryOwner>,
  "eventType": "workflow_job",
  "installationId": <installationId>
}
EOF
  }
}

# Allow EventBridge to send messages to SQS
resource "aws_sqs_queue_policy" "cb_builds" {
  for_each = local.cb_runners

  queue_url = aws_sqs_queue.cb_builds[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.cb_builds[each.key].arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_cloudwatch_event_rule.cb_workflow_job[each.key].arn
          }
        }
      }
    ]
  })
}

# =============================================================================
# Lambda Function - CB Scale-Up
# =============================================================================

data "archive_file" "cb_scale_up" {
  type        = "zip"
  source_file = "${path.module}/lambdas/cb-scale-up/index.py"
  output_path = "${path.module}/lambdas/cb-scale-up/lambda.zip"
}

resource "aws_lambda_function" "cb_scale_up" {
  for_each = local.cb_runners

  filename         = data.archive_file.cb_scale_up.output_path
  source_code_hash = data.archive_file.cb_scale_up.output_base64sha256
  function_name    = "${local.environment}-${each.key}-scale-up"
  role             = aws_iam_role.cb_scale_up.arn
  handler          = "index.handler"
  runtime          = "python3.11"
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      AWS_REGION           = var.aws_region
      ENVIRONMENT          = local.environment
      LAUNCH_TEMPLATE_NAME = aws_launch_template.cb_runner[each.key].name
      SUBNET_IDS           = join(",", module.vpc.private_subnets)
      INSTANCE_TYPE        = each.value.instance_type
      RUNNER_NAME_PREFIX   = "${local.environment}-${each.key}-"
      SSM_CONFIG_PATH      = "/github-action-runners/${local.environment}/${each.key}/runners/config"
    }
  }

  tags = {
    Name        = "${local.environment}-${each.key}-scale-up"
    Environment = local.environment
    Project     = "FlashInfer"
    ManagedBy   = "Terraform"
  }
}

# SQS trigger for Lambda
resource "aws_lambda_event_source_mapping" "cb_scale_up" {
  for_each = local.cb_runners

  event_source_arn                   = aws_sqs_queue.cb_builds[each.key].arn
  function_name                      = aws_lambda_function.cb_scale_up[each.key].arn
  batch_size                         = 1
  function_response_types            = ["ReportBatchItemFailures"]
  maximum_batching_window_in_seconds = 0
}

# =============================================================================
# IAM Role for CB Scale-Up Lambda
# =============================================================================

resource "aws_iam_role" "cb_scale_up" {
  name = "${local.environment}-cb-scale-up-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Environment = local.environment
    Project     = "FlashInfer"
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy" "cb_scale_up" {
  name = "${local.environment}-cb-scale-up-policy"
  role = aws_iam_role.cb_scale_up.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = [for q in aws_sqs_queue.cb_builds : q.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeCapacityReservations",
          "ec2:DescribeSubnets",
          "ec2:DescribeInstances",
          "ec2:RunInstances",
          "ec2:CreateTags"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "iam:PassRole"
        ]
        Resource = aws_iam_role.cb_runner.arn
      }
    ]
  })
}

# =============================================================================
# Launch Template for CB Instances
# =============================================================================

resource "aws_launch_template" "cb_runner" {
  for_each = local.cb_runners

  name        = "${local.environment}-${each.key}-launch-template"
  description = "Launch template for ${each.value.description} CB runners"

  # Use Deep Learning AMI
  image_id = data.aws_ami.deep_learning.id

  # Instance type set at launch time
  # instance_type = each.value.instance_type

  # IAM instance profile
  iam_instance_profile {
    name = aws_iam_instance_profile.cb_runner.name
  }

  # Network
  vpc_security_group_ids = [aws_security_group.cb_runner.id]

  # Storage - 500GB for deep learning workloads
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 500
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  # Metadata options
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  # User data - multi-GPU runner setup
  user_data = base64encode(file("${path.module}/templates/user-data-multi-gpu.sh"))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${local.environment}-${each.key}-action-runner"
      Environment = local.environment
      Project     = "FlashInfer"
      ManagedBy   = "Terraform"
    }
  }

  tags = {
    Name        = "${local.environment}-${each.key}-launch-template"
    Environment = local.environment
    Project     = "FlashInfer"
    ManagedBy   = "Terraform"
  }
}

# Deep Learning AMI
data "aws_ami" "deep_learning" {
  most_recent = true
  owners      = ["898082745236"]  # AWS Deep Learning AMI owner

  filter {
    name   = "name"
    values = ["Deep Learning OSS Nvidia Driver AMI GPU PyTorch 2.* (Ubuntu 22.04) *"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# =============================================================================
# IAM Role for CB Runner Instances
# =============================================================================

resource "aws_iam_role" "cb_runner" {
  name = "${local.environment}-cb-runner"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Environment = local.environment
    Project     = "FlashInfer"
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_instance_profile" "cb_runner" {
  name = "${local.environment}-cb-runner"
  role = aws_iam_role.cb_runner.name
}

resource "aws_iam_role_policy" "cb_runner" {
  name = "${local.environment}-cb-runner-policy"
  role = aws_iam_role.cb_runner.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/github-action-runners/${local.environment}/*"
      },
      {
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
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "arn:aws:s3:::${local.environment}-runner-binaries/*"
      }
    ]
  })
}

# =============================================================================
# Security Group for CB Runners
# =============================================================================

resource "aws_security_group" "cb_runner" {
  name        = "${local.environment}-cb-runner-sg"
  description = "Security group for CB runner instances"
  vpc_id      = module.vpc.vpc_id

  # Outbound - allow all
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name        = "${local.environment}-cb-runner-sg"
    Environment = local.environment
    Project     = "FlashInfer"
    ManagedBy   = "Terraform"
  }
}

# =============================================================================
# CB Manager Lambda (Status Checker - Read Only)
# =============================================================================

data "archive_file" "cb_manager" {
  type        = "zip"
  source_file = "${path.module}/lambdas/cb-manager/index.py"
  output_path = "${path.module}/lambdas/cb-manager/lambda.zip"
}

resource "aws_lambda_function" "cb_manager" {
  filename         = data.archive_file.cb_manager.output_path
  source_code_hash = data.archive_file.cb_manager.output_base64sha256
  function_name    = "${local.environment}-cb-manager"
  role             = aws_iam_role.cb_manager.arn
  handler          = "index.handler"
  runtime          = "python3.11"
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      AWS_REGION  = var.aws_region
      ENVIRONMENT = local.environment
    }
  }

  tags = {
    Name        = "${local.environment}-cb-manager"
    Environment = local.environment
    Project     = "FlashInfer"
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role" "cb_manager" {
  name = "${local.environment}-cb-manager-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "cb_manager" {
  name = "${local.environment}-cb-manager-policy"
  role = aws_iam_role.cb_manager.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeCapacityReservations"
        ]
        Resource = "*"
      }
    ]
  })
}

# =============================================================================
# Outputs
# =============================================================================

output "cb_queues" {
  description = "CB SQS queues"
  value = {
    for k, q in aws_sqs_queue.cb_builds : k => {
      name = q.name
      arn  = q.arn
      url  = q.url
    }
  }
}

output "cb_lambdas" {
  description = "CB scale-up Lambda functions"
  value = {
    for k, l in aws_lambda_function.cb_scale_up : k => {
      name = l.function_name
      arn  = l.arn
    }
  }
}
