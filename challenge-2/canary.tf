# canary.tf
# Full detection + enrichment + automated response + real-time pipeline

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

# ─────────────────────────────────────────────────────────────
# CLOUDTRAIL
# ─────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket = "${var.project_name}-cloudtrail-logs-${data.aws_caller_identity.current.account_id}"
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  bucket                  = aws_s3_bucket.cloudtrail_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail_logs.arn
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/${var.project_name}"
  retention_in_days = 90
  tags              = var.tags
}

resource "aws_iam_role" "cloudtrail_to_cloudwatch" {
  name = "${var.project_name}-cloudtrail-cw-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cloudtrail_to_cloudwatch" {
  name = "${var.project_name}-cloudtrail-cw-policy"
  role = aws_iam_role.cloudtrail_to_cloudwatch.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
    }]
  })
}

resource "aws_cloudtrail" "main" {
  name                          = "${var.project_name}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail_to_cloudwatch.arn
  depends_on                    = [aws_s3_bucket_policy.cloudtrail_logs]
  tags                          = var.tags
}

# ─────────────────────────────────────────────────────────────
# REAL-TIME DETECTION (CloudWatch Logs → Lambda)
# ─────────────────────────────────────────────────────────────

resource "aws_lambda_permission" "allow_logs" {
  statement_id  = "AllowCloudWatchLogsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.canary_response.function_name
  principal     = "logs.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
}

resource "aws_cloudwatch_log_subscription_filter" "canary_realtime" {
  name            = "${var.project_name}-realtime-filter"
  log_group_name  = aws_cloudwatch_log_group.cloudtrail.name
  filter_pattern  = "{ $.userIdentity.accessKeyId = \"${var.canary_access_key_id}\" }"
  destination_arn = aws_lambda_function.canary_response.arn

  depends_on = [aws_lambda_permission.allow_logs]
}

# ─────────────────────────────────────────────────────────────
# SECRETS MANAGER
# ─────────────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "chronicle" {
  name        = "${var.project_name}-chronicle-api-key"
  description = "Chronicle SIEM API key"
}

resource "aws_secretsmanager_secret_version" "chronicle" {
  secret_id     = aws_secretsmanager_secret.chronicle.id
  secret_string = var.chronicle_api_key
}

# ─────────────────────────────────────────────────────────────
# SNS
# ─────────────────────────────────────────────────────────────

resource "aws_sns_topic" "canary_alerts" {
  name = "${var.project_name}-canary-alerts"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "canary_email" {
  topic_arn = aws_sns_topic.canary_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ─────────────────────────────────────────────────────────────
# SQS DLQ
# ─────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "canary_dlq" {
  name                      = "${var.project_name}-canary-dlq"
  message_retention_seconds = 1209600
  tags                      = var.tags
}

# ─────────────────────────────────────────────────────────────
# IAM ROLE
# ─────────────────────────────────────────────────────────────

resource "aws_iam_role" "canary_lambda" {
  name = "${var.project_name}-canary-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "canary_lambda" {
  name = "${var.project_name}-canary-lambda-policy"
  role = aws_iam_role.canary_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [

      {
        Sid    = "WriteLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project_name}-canary-response:*"
        ]
      },

      {
        Sid    = "DisableCanaryKey"
        Effect = "Allow"
        Action = ["iam:UpdateAccessKey"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/canary-do-not-use"
      },

      {
        Sid    = "PublishAlert"
        Effect = "Allow"
        Action = ["sns:Publish"]
        Resource = [aws_sns_topic.canary_alerts.arn]
      },

      {
        Sid    = "CreateFinding"
        Effect = "Allow"
        Action = ["securityhub:BatchImportFindings"]
        Resource = "*"
      },

      {
        Sid    = "GetAccountId"
        Effect = "Allow"
        Action = ["sts:GetCallerIdentity"]
        Resource = "*"
      },

      {
        Sid    = "WriteToDLQ"
        Effect = "Allow"
        Action = ["sqs:SendMessage"]
        Resource = [aws_sqs_queue.canary_dlq.arn]
      },

      {
        Sid    = "ReadSecrets"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.chronicle.arn]
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────
# LAMBDA
# ─────────────────────────────────────────────────────────────

data "archive_file" "canary_response" {
  type        = "zip"
  source_file = "${path.module}/canary_response.py"
  output_path = "${path.module}/canary_response.zip"
}

resource "aws_lambda_function" "canary_response" {
  function_name = "${var.project_name}-canary-response"
  role          = aws_iam_role.canary_lambda.arn
  handler       = "canary_response.lambda_handler"
  runtime       = "python3.12"
  timeout       = 120
  memory_size   = 128

  filename         = data.archive_file.canary_response.output_path
  source_code_hash = data.archive_file.canary_response.output_base64sha256

  environment {
    variables = {
      SNS_TOPIC_ARN        = aws_sns_topic.canary_alerts.arn
      CANARY_ACCESS_KEY_ID = var.canary_access_key_id

      GEOIP_API_URL        = var.geoip_api_url
      THREAT_INTEL_API_URL = var.threat_intel_api_url

      CHRONICLE_ENDPOINT   = var.chronicle_endpoint
      CHRONICLE_API_KEY_SECRET_ARN = aws_secretsmanager_secret.chronicle.arn

      ENABLE_AUTO_RESPONSE = "false"
    }
  }

  reserved_concurrent_executions = 1

  dead_letter_config {
    target_arn = aws_sqs_queue.canary_dlq.arn
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "canary_response" {
  name              = "/aws/lambda/${aws_lambda_function.canary_response.function_name}"
  retention_in_days = 90
  tags              = var.tags
}

# ─────────────────────────────────────────────────────────────
# EVENTBRIDGE (fallback detection)
# ─────────────────────────────────────────────────────────────

resource "aws_cloudwatch_event_rule" "canary_triggered" {
  name = "${var.project_name}-canary-triggered"

  event_pattern = jsonencode({
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      userIdentity = {
        accessKeyId = [var.canary_access_key_id]
      }
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "canary_lambda" {
  rule      = aws_cloudwatch_event_rule.canary_triggered.name
  target_id = "CanaryLambda"
  arn       = aws_lambda_function.canary_response.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.canary_response.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.canary_triggered.arn
}

# ─────────────────────────────────────────────────────────────
# DLQ ALARM
# ─────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "canary_dlq_depth" {
  alarm_name          = "${var.project_name}-canary-dlq-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0

  alarm_actions = [aws_sns_topic.canary_alerts.arn]

  dimensions = {
    QueueName = aws_sqs_queue.canary_dlq.name
  }

  tags = var.tags
}