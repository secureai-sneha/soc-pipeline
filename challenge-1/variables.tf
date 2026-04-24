# variables.tf
# ─────────────────────────────────────────────────────────────────────────────
# Input variables for the pipeline.
# These variables are to be changed to customise the deployment without touching main.tf.
# ─────────────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy all resources into"
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Prefix applied to every resource name to avoid conflicts"
  type        = string
  default     = "soc-pipeline"
}

variable "source_log_group" {
  description = "CloudWatch log group of the money transfer application"
  type        = string
  default     = "/aws/lambda/money-transfer-service"
}

variable "tags" {
  description = "Tags applied to every AWS resource for cost tracking"
  type        = map(string)
  default = {
    Project     = "soc-pipeline"
    Environment = "poc"
    ManagedBy   = "terraform"
  }
}

variable "alert_email" {
  description = "Email address to receive pipeline alert notifications"
  type        = string
}

variable "canary_access_key_id" {
  description = "Access key ID of the canary IAM user"
  type        = string
  sensitive   = true
}

variable "project_name" {
  description = "Prefix for all resource names"
  type        = string
  default     = "canary-detection"
}

variable "alert_email" {
  description = "Email address for canary alert notifications"
  type        = string
}

variable "chronicle_api_key" {
  description = "Chronicle SIEM API key (leave empty if not using)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "chronicle_endpoint" {
  description = "Chronicle UDM ingestion endpoint"
  type        = string
  default     = ""
}

variable "geoip_api_url" {
  description = "GeoIP API base URL (optional)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = { Project = "canary-detection", ManagedBy = "terraform" }
}

# ─────────────────────────────────────────────────────────────────────────────
# outputs.tf
# Values printed after terraform apply completes.
# Useful for knowing what was created.
# ─────────────────────────────────────────────────────────────────────────────

output "data_lake_bucket_name" {
  description = "Name of the S3 bucket where enriched logs are stored"
  value       = aws_s3_bucket.data_lake.id
}

output "firehose_stream_name" {
  description = "Name of the Kinesis Firehose delivery stream"
  value       = aws_kinesis_firehose_delivery_stream.pipeline.name
}

output "processor_lambda_name" {
  description = "Name of the enrichment Lambda function"
  value       = aws_lambda_function.processor.function_name
}