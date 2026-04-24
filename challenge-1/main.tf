# main.tf
# ─────────────────────────────────────────────────────────────────────────────
# Deploys the complete Part 1 logging pipeline:
#
#   CloudWatch Logs
#     → Subscription Filter
#       → Kinesis Firehose
#         → Enrichment Lambda (processor.py)
#           → S3 Data Lake
#
# All resources are named using the var.project_name prefix so
# nothing conflicts if deployed in multiple environments.
# ─────────────────────────────────────────────────────────────────────────────

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

# Used to safely construct scoped ARNs without hardcoding account IDs
data "aws_caller_identity" "current" {}

# ─────────────────────────────────────────────────────────────────────────────
# S3 — DATA LAKE
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "data_lake" {
  bucket = "${var.project_name}-data-lake"
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "data_lake" {
  bucket                  = aws_s3_bucket.data_lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id
  rule {
    id     = "tiered-storage"
    status = "Enabled"
    transition { days = 30;  storage_class = "STANDARD_IA" }
    transition { days = 90;  storage_class = "GLACIER" }
    expiration { days = 730 }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# SNS — PIPELINE ALERT TOPIC
# Alarms need a real SNS topic to publish to.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_sns_topic" "pipeline_alerts" {
  name = "${var.project_name}-pipeline-alerts"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "pipeline_email" {
  topic_arn = aws_sns_topic.pipeline_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM — FIREHOSE ROLE
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "firehose" {
  name = "${var.project_name}-firehose-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "firehose" {
  name = "${var.project_name}-firehose-policy"
  role = aws_iam_role.firehose.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteToS3"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetBucketLocation", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.data_lake.arn,
          "${aws_s3_bucket.data_lake.arn}/*"
        ]
      },
      {
        Sid      = "InvokeLambda"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.processor.arn]
      },
      {
        Sid      = "WriteDeliveryLogs"
        Effect   = "Allow"
        Action   = ["logs:PutLogEvents"]
        Resource = [
          # Scoped to the Firehose log group only, not the whole account
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/kinesisfirehose/${var.project_name}:*"
        ]
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM — LAMBDA EXECUTION ROLE
# Scoped to this Lambda's own log group, not the entire account.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "processor_lambda" {
  name = "${var.project_name}-processor-lambda-role"
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

resource "aws_iam_role_policy" "processor_lambda" {
  name = "${var.project_name}-processor-lambda-policy"
  role = aws_iam_role.processor_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "WriteLogs"
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      # Scoped to this Lambda's log group only
      Resource = [
        "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project_name}-processor:*"
      ]
    }]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# LAMBDA — PROCESSOR
# ─────────────────────────────────────────────────────────────────────────────

data "archive_file" "processor" {
  type        = "zip"
  source_file = "${path.module}/processor.py"
  output_path = "${path.module}/processor.zip"
}

resource "aws_lambda_function" "processor" {
  function_name    = "${var.project_name}-processor"
  role             = aws_iam_role.processor_lambda.arn
  handler          = "processor.lambda_handler"
  runtime          = "python3.12"
  timeout          = 300
  memory_size      = 128
  filename         = data.archive_file.processor.output_path
  source_code_hash = data.archive_file.processor.output_base64sha256

  environment {
    variables = {
      HIGH_VALUE_THRESHOLD = "10000"
    }
  }

  tags = var.tags
}

# Must be created before the IAM policy references it
resource "aws_cloudwatch_log_group" "processor" {
  name              = "/aws/lambda/${aws_lambda_function.processor.function_name}"
  retention_in_days = 30
  tags              = var.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# KINESIS FIREHOSE
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_kinesis_firehose_delivery_stream" "pipeline" {
  name        = "${var.project_name}-delivery-stream"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = aws_s3_bucket.data_lake.arn

    prefix              = "logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/"
    error_output_prefix = "errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"

    buffering_size     = 5
    buffering_interval = 60
    compression_format = "GZIP"

    processing_configuration {
      enabled = true
      processors {
        type = "Lambda"
        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = "${aws_lambda_function.processor.arn}:$LATEST"
        }
        parameters {
          parameter_name  = "NumberOfRetries"
          parameter_value = "3"
        }
      }
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = "/aws/kinesisfirehose/${var.project_name}"
      log_stream_name = "S3Delivery"
    }
  }

  tags = var.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# CLOUDWATCH SUBSCRIPTION FILTER
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "cloudwatch_to_firehose" {
  name = "${var.project_name}-cw-to-firehose-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cloudwatch_to_firehose" {
  name = "${var.project_name}-cw-to-firehose-policy"
  role = aws_iam_role.cloudwatch_to_firehose.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
      Resource = [aws_kinesis_firehose_delivery_stream.pipeline.arn]
    }]
  })
}

resource "aws_cloudwatch_log_subscription_filter" "transfer_logs" {
  name            = "${var.project_name}-subscription-filter"
  log_group_name  = var.source_log_group
  filter_pattern  = "{ $.action = \"TRANSFER*\" }"
  destination_arn = aws_kinesis_firehose_delivery_stream.pipeline.arn
  role_arn        = aws_iam_role.cloudwatch_to_firehose.arn
}

# ─────────────────────────────────────────────────────────────────────────────
# CLOUDWATCH ALARMS
# Alarms are now deployed as real Terraform resources.
# ─────────────────────────────────────────────────────────────────────────────

# Alert: Firehose is not delivering data to S3 fast enough.
# DataFreshness rising means the Lambda is slow, throttled, or erroring.
resource "aws_cloudwatch_metric_alarm" "firehose_freshness" {
  alarm_name          = "${var.project_name}-firehose-data-freshness"
  alarm_description   = "Firehose delivery lag too high. Lambda may be slow or throttled."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DeliveryToS3.DataFreshness"
  namespace           = "AWS/Firehose"
  period              = 60
  statistic           = "Maximum"
  threshold           = 300   # alert if records are more than 5 minutes old
  alarm_actions       = [aws_sns_topic.pipeline_alerts.arn]
  ok_actions          = [aws_sns_topic.pipeline_alerts.arn]
  dimensions = {
    DeliveryStreamName = aws_kinesis_firehose_delivery_stream.pipeline.name
  }
  tags = var.tags
}

# Alert: S3 delivery success rate dropped below 99%.
# This fires when records are consistently failing to reach S3.
resource "aws_cloudwatch_metric_alarm" "firehose_delivery_success" {
  alarm_name          = "${var.project_name}-firehose-delivery-success"
  alarm_description   = "Firehose S3 delivery success rate below 99%. Check errors/ prefix."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DeliveryToS3.Success"
  namespace           = "AWS/Firehose"
  period              = 60
  statistic           = "Average"
  threshold           = 0.99
  alarm_actions       = [aws_sns_topic.pipeline_alerts.arn]
  dimensions = {
    DeliveryStreamName = aws_kinesis_firehose_delivery_stream.pipeline.name
  }
  tags = var.tags
}

# Alert: Lambda is throwing errors.
# Any Lambda error means a bug or a schema change in the upstream application.
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project_name}-lambda-errors"
  alarm_description   = "Enrichment Lambda is erroring. Check logs for schema issues."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_actions       = [aws_sns_topic.pipeline_alerts.arn]
  dimensions = {
    FunctionName = aws_lambda_function.processor.function_name
  }
  tags = var.tags
}

# Alert: Lambda is being throttled.
# Throttling means reserved concurrency is exhausted — records are backing up.
resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  alarm_name          = "${var.project_name}-lambda-throttles"
  alarm_description   = "Enrichment Lambda is being throttled. Records may be delayed."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_actions       = [aws_sns_topic.pipeline_alerts.arn]
  dimensions = {
    FunctionName = aws_lambda_function.processor.function_name
  }
  tags = var.tags
}

# Alert: Lambda is approaching the Firehose transformation timeout.
# If p99 duration exceeds 270s, Firehose will start timing out invocations.
resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  alarm_name          = "${var.project_name}-lambda-duration-p99"
  alarm_description   = "Lambda p99 duration approaching Firehose 300s timeout limit."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 60
  extended_statistic  = "p99"
  threshold           = 270000   # milliseconds
  alarm_actions       = [aws_sns_topic.pipeline_alerts.arn]
  dimensions = {
    FunctionName = aws_lambda_function.processor.function_name
  }
  tags = var.tags