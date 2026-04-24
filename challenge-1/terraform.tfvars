# terraform.tfvars

# Required — no default exists
alert_email = "soc-team@company.com"

# Optional overrides — defaults exist but  likely to be changed as per environment
aws_region       = "eu-west-1"
project_name     = "soc-pipeline"
source_log_group = "/aws/lambda/money-transfer-service"

tags = {
  Project     = "soc-pipeline"
  Environment = "poc"
  ManagedBy   = "terraform"
}