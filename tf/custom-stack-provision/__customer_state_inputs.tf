# Inputs needed to read the cloud-provision remote state and choose the role/region
variable "short_project_id" { type = string }
variable "bootstrap_state_bucket" { type = string }
variable "bootstrap_state_region" { type = string }
variable "bootstrap_state_env" { type = string }
variable "bootstrap_state_kms_key_id" { type = string }

# ============================================================================
# Cloud Provider Selection
# ============================================================================

variable "cloud_provider" {
  description = "Cloud provider: aws or gcp"
  type        = string
  default     = "aws"
}

# ============================================================================
# AWS Variables
# ============================================================================

variable "aws_region" {
  description = "AWS region (required for AWS deployments)"
  type        = string
  default     = ""
}

# ============================================================================
# GCP Variables
# ============================================================================

variable "gcp_project_id" {
  description = "GCP project ID (required for GCP deployments)"
  type        = string
  default     = ""
}

variable "gcp_region" {
  description = "GCP region (required for GCP deployments)"
  type        = string
  default     = ""
}

variable "gcp_credentials_b64" {
  description = "Base64-encoded GCP service account JSON key (handled by shell_utils.sh)"
  type        = string
  default     = ""
  sensitive   = true
}
