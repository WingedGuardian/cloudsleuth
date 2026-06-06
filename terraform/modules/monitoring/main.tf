variable "environment" {}
variable "primary_instance_id" {}
variable "primary_public_ip" {}
variable "primary_region" {}
variable "secondary_instance_id" {}
variable "secondary_region" {}
variable "ssm_role_arn" {}
variable "primary_endpoint_group_arn" {}
variable "secondary_endpoint_group_arn" {}
variable "app_port" {}

# --- State table (anomaly detector persists baselines here) ---

resource "aws_dynamodb_table" "detector_state" {
  name         = "cloudsleuth-${var.environment}-detector-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

# --- SNS for alerts ---

resource "aws_sns_topic" "alerts" {
  name = "cloudsleuth-${var.environment}-alerts"
}

# --- Route53 health check on the primary instance ---

resource "aws_route53_health_check" "primary" {
  ip_address        = var.primary_public_ip
  port              = var.app_port
  type              = "HTTP"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 10

  tags = { Name = "cloudsleuth-${var.environment}-primary" }
}

resource "aws_cloudwatch_metric_alarm" "health_check_failed" {
  alarm_name          = "cloudsleuth-${var.environment}-primary-down"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    HealthCheckId = aws_route53_health_check.primary.id
  }
}

# --- Lambda: anomaly detector ---

data "archive_file" "detector" {
  type        = "zip"
  source_dir  = "${path.root}/../anomaly_detector"
  output_path = "${path.root}/../build/detector.zip"
}

resource "aws_lambda_function" "detector" {
  filename         = data.archive_file.detector.output_path
  source_code_hash = data.archive_file.detector.output_base64sha256
  function_name    = "cloudsleuth-${var.environment}-detector"
  role             = aws_iam_role.detector.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      PRIMARY_INSTANCE_ID          = var.primary_instance_id
      PRIMARY_REGION               = var.primary_region
      SECONDARY_INSTANCE_ID        = var.secondary_instance_id
      SECONDARY_REGION             = var.secondary_region
      SNS_TOPIC_ARN                = aws_sns_topic.alerts.arn
      STATE_TABLE                  = aws_dynamodb_table.detector_state.name
      SSM_DOCUMENT                 = aws_ssm_document.failover.name
      SSM_ROLE_ARN                 = var.ssm_role_arn
      PRIMARY_ENDPOINT_GROUP_ARN   = var.primary_endpoint_group_arn
      SECONDARY_ENDPOINT_GROUP_ARN = var.secondary_endpoint_group_arn
      APP_PORT                     = var.app_port
    }
  }
}

# trigger every minute
resource "aws_cloudwatch_event_rule" "every_minute" {
  name                = "cloudsleuth-${var.environment}-detector-schedule"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "detector" {
  rule = aws_cloudwatch_event_rule.every_minute.name
  arn  = aws_lambda_function.detector.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.detector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.every_minute.arn
}

# --- Lambda execution role ---

resource "aws_iam_role" "detector" {
  name = "cloudsleuth-${var.environment}-detector"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "detector" {
  role = aws_iam_role.detector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "MetricsRead"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricData", "cloudwatch:DescribeAlarms"]
        Resource = "*"
      },
      {
        Sid      = "DetectorState"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem"]
        Resource = aws_dynamodb_table.detector_state.arn
      },
      {
        Sid      = "Alerts"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Sid      = "EC2Describe"
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      },
      {
        Sid      = "EC2StartSecondary"
        Effect   = "Allow"
        Action   = "ec2:StartInstances"
        Resource = "*"
        Condition = {
          StringEquals = { "aws:ResourceTag/Project" = "cloudsleuth" }
        }
      },
      {
        Sid      = "AcceleratorManage"
        Effect   = "Allow"
        Action   = ["globalaccelerator:UpdateEndpointGroup", "globalaccelerator:DescribeEndpointGroup"]
        Resource = "*"
      },
      {
        Sid      = "SSMTrigger"
        Effect   = "Allow"
        Action   = "ssm:StartAutomationExecution"
        Resource = "arn:aws:ssm:*:*:automation-definition/cloudsleuth-*"
      },
      {
        Sid      = "SSMPassRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = var.ssm_role_arn
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:log-group:/aws/lambda/cloudsleuth-*"
      }
    ]
  })
}

# --- SSM Automation document ---

resource "aws_ssm_document" "failover" {
  name            = "cloudsleuth-${var.environment}-failover"
  document_type   = "Automation"
  document_format = "YAML"

  content = templatefile("${path.module}/failover.yaml.tftpl", {
    ssm_role_arn                 = var.ssm_role_arn
    secondary_instance_id        = var.secondary_instance_id
    secondary_region             = var.secondary_region
    primary_endpoint_group_arn   = var.primary_endpoint_group_arn
    secondary_endpoint_group_arn = var.secondary_endpoint_group_arn
    sns_topic_arn                = aws_sns_topic.alerts.arn
  })
}

# --- Outputs ---

output "detector_function_name" {
  value = aws_lambda_function.detector.function_name
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "detector_table_arn" {
  value = aws_dynamodb_table.detector_state.arn
}
