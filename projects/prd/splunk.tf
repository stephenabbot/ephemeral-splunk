# Production environment configuration for ephemeral Splunk
# This file exists to maintain consistency with project patterns
# Configuration is handled through .env file and main.tf variables

locals {
  environment = "prd"
  
  # Environment-specific overrides can be added here if needed
  # For now, all configuration comes from .env and main.tf defaults
}
