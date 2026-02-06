# A100 GPU runners (p4d.24xlarge) - Spot with on-demand fallback
# 5 runners per instance: 1x 4-GPU (GPUs 0-3) + 4x 1-GPU (GPUs 4-7)
# Uses same user-data-multi-runner.sh as p5/p6 CB runners

locals {
  p4d_config = {
    instance_type = "p4d.24xlarge"
    gpu_type      = "a100"
    labels        = ["sm80", "a100"]
    labels_base   = "self-hosted,linux,x64,gpu,nvidia,a100,sm80"
    description   = "A100 GPU (Ampere)"
  }
}

# SQS queue for p4d job requests
resource "aws_sqs_queue" "p4d_builds" {
  name                       = "${local.environment}-gpu-p4d-queued-builds"
  delay_seconds              = 30  # Short delay (no CB activation needed)
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400  # 24 hours

  tags = {
    Name        = "${local.environment}-gpu-p4d-queued-builds"
    Environment = local.environment
    Project     = "FlashInfer"
    ManagedBy   = "Terraform"
  }
}

# EventBridge rule to route a100/sm80 jobs to p4d queue
resource "aws_cloudwatch_event_rule" "p4d_workflow_job" {
  name           = "${local.environment}-gpu-p4d-workflow-job"
  description    = "Route A100 jobs to p4d queue"
  event_bus_name = module.runners.webhook.eventbridge.event_bus.name

  event_pattern = jsonencode({
    source      = ["github"]
    detail-type = ["workflow_job"]
    detail = {
      action = ["queued"]
      workflow_job = {
        labels = [{ prefix = "a100" }]
      }
    }
  })

  tags = {
    Environment = local.environment
    Project     = "FlashInfer"
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_event_target" "p4d_sqs" {
  rule           = aws_cloudwatch_event_rule.p4d_workflow_job.name
  event_bus_name = module.runners.webhook.eventbridge.event_bus.name
  target_id      = "gpu-p4d-sqs"
  arn            = aws_sqs_queue.p4d_builds.arn

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

resource "aws_sqs_queue_policy" "p4d_builds" {
  queue_url = aws_sqs_queue.p4d_builds.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.p4d_builds.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_cloudwatch_event_rule.p4d_workflow_job.arn
          }
        }
      }
    ]
  })
}

# Lambda function for p4d scale-up (spot with on-demand fallback)
data "archive_file" "p4d_scale_up" {
  type        = "zip"
  source_file = "${path.module}/lambdas/p4d-scale-up/index.py"
  output_path = "${path.module}/lambdas/p4d-scale-up/lambda.zip"
}

resource "aws_lambda_function" "p4d_scale_up" {
  filename         = data.archive_file.p4d_scale_up.output_path
  source_code_hash = data.archive_file.p4d_scale_up.output_base64sha256
  function_name    = "${local.environment}-gpu-p4d-scale-up"
  role             = aws_iam_role.p4d_scale_up.arn
  handler          = "index.handler"
  runtime          = "python3.11"
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      REGION               = var.aws_region
      ENVIRONMENT          = local.environment
      LAUNCH_TEMPLATE_NAME = aws_launch_template.p4d_runner.name
      SUBNET_IDS           = join(",", module.vpc.public_subnets)
      INSTANCE_TYPE        = local.p4d_config.instance_type
      RUNNER_NAME_PREFIX   = "${local.environment}-p4d-"
      SSM_CONFIG_PATH      = "/github-action-runners/${local.environment}/gpu-p4d/runners/config"
    }
  }

  tags = {
    Name        = "${local.environment}-gpu-p4d-scale-up"
    Environment = local.environment
    Project     = "FlashInfer"
    ManagedBy   = "Terraform"
  }
}

resource "aws_lambda_event_source_mapping" "p4d_scale_up" {
  event_source_arn                   = aws_sqs_queue.p4d_builds.arn
  function_name                      = aws_lambda_function.p4d_scale_up.arn
  batch_size                         = 1
  function_response_types            = ["ReportBatchItemFailures"]
  maximum_batching_window_in_seconds = 0
}

# IAM role for p4d scale-up Lambda
resource "aws_iam_role" "p4d_scale_up" {
  name = "${local.environment}-p4d-scale-up-lambda"

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

resource "aws_iam_role_policy" "p4d_scale_up" {
  name = "${local.environment}-p4d-scale-up-policy"
  role = aws_iam_role.p4d_scale_up.id

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
        Resource = aws_sqs_queue.p4d_builds.arn
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeSubnets",
          "ec2:DescribeInstances",
          "ec2:RunInstances",
          "ec2:CreateTags",
          "ec2:CreateFleet"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.cb_runner.arn  # Reuse CB runner IAM role
      }
    ]
  })
}

# Launch template for p4d instances
resource "aws_launch_template" "p4d_runner" {
  name        = "${local.environment}-gpu-p4d-launch-template"
  description = "Launch template for A100 (p4d.24xlarge) runners"

  image_id = data.aws_ami.deep_learning.id

  iam_instance_profile {
    name = aws_iam_instance_profile.cb_runner.name  # Reuse CB runner profile
  }

  vpc_security_group_ids = [aws_security_group.cb_runner.id]  # Reuse CB runner SG

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

  user_data = base64encode(templatefile("${path.module}/templates/user-data-multi-runner.sh", {
    region               = var.aws_region
    environment          = local.environment
    instance_type        = local.p4d_config.instance_type
    gpu_type             = local.p4d_config.gpu_type
    ssm_config_path      = "/github-action-runners/${local.environment}/gpu-p4d/runners/config"
    github_app_id_param  = "/github-action-runners/${local.environment}/app/github_app_id"
    github_app_key_param = "/github-action-runners/${local.environment}/app/github_app_key_base64"
    org_name             = "flashinfer-ai"
    runner_group         = "Default"
    labels_base          = local.p4d_config.labels_base
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${local.environment}-gpu-p4d-action-runner"
      Environment = local.environment
      Project     = "FlashInfer"
      ManagedBy   = "Terraform"
    }
  }

  tags = {
    Name        = "${local.environment}-gpu-p4d-launch-template"
    Environment = local.environment
    Project     = "FlashInfer"
    ManagedBy   = "Terraform"
  }
}

# Outputs
output "p4d_queue" {
  description = "P4D SQS queue"
  value = {
    name = aws_sqs_queue.p4d_builds.name
    arn  = aws_sqs_queue.p4d_builds.arn
    url  = aws_sqs_queue.p4d_builds.id
  }
}

output "p4d_lambda" {
  description = "P4D scale-up Lambda"
  value = {
    name = aws_lambda_function.p4d_scale_up.function_name
    arn  = aws_lambda_function.p4d_scale_up.arn
  }
}
