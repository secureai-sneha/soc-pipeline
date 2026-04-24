# canary_variables.tf
# ─────────────────────────────────────────────────────────────────────────────
# Input variables for the canary detection system.
# ─────────────────────────────────────────────────────────────────────────────


variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "ap-south-1"

  validation {
    condition     = length(var.aws_region) > 0
    error_message = "AWS region must not be empty."
  }
}

variable "threat_intel_api_url" {
  description = "Threat intelligence API endpoint (optional)"
  type        = string
  default     = ""
}

variable "enable_auto_response" {
  description = "Enable automated response actions (disable for safe testing)"
  type        = bool
  default     = false
}

variable "enable_realtime_detection" {
  description = "Enable real-time detection via CloudWatch Logs"
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 90
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "poc"
}