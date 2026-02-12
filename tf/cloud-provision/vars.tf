# ============================================================================
# Cloud Provider Selection
# ============================================================================

variable "cloud_provider" {
  description = "Cloud provider: aws or gcp"
  type        = string
  default     = "aws"

  validation {
    condition     = contains(["aws", "gcp"], var.cloud_provider)
    error_message = "cloud_provider must be either 'aws' or 'gcp'"
  }
}

# ============================================================================
# Common Variables
# ============================================================================

variable "domain" {
  type = string
}

variable "short_project_id" {
  type = string
}

variable "project_id" {
  type = string
}

variable "luther_env" {
  type    = string
  default = ""
}

variable "org_name" {
  type    = string
  default = ""
}

variable "terraform_sa_role" {
  type    = string
  default = ""
}

variable "create_dns" {
  type    = bool
  default = true
}

variable "repo_org" {
  type    = string
  default = "luthersystems"
}

variable "github_username" {
  description = "GitHub username to invite as collaborator on the infra repo"
  type        = string
  default     = ""
}

# ============================================================================
# AWS Variables (required when cloud_provider = aws)
# ============================================================================

variable "aws_region" {
  description = "AWS region (required for AWS deployments)"
  type        = string
  default     = ""
}

variable "bootstrap_role" {
  description = "AWS IAM role ARN for Terraform (required for AWS deployments)"
  type        = string
  default     = ""
}

# ============================================================================
# GCP Variables (required when cloud_provider = gcp)
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
