# Inputs needed to read the cloud-provision remote state and choose the role/region
variable "short_project_id" { type = string }
variable "project_id" {
  description = "Full Luther project ID"
  type        = string
}
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

# ============================================================================
# Custom Stack Variables (passed by workflow, used by prepare-custom-stack)
# ============================================================================

variable "custom_repo_url" {
  description = "Git repository URL for custom stack terraform"
  type        = string
  default     = ""
}

variable "custom_ref" {
  description = "Git ref (branch/tag) for custom stack terraform"
  type        = string
  default     = "main"
}

variable "custom_auth" {
  description = "Auth method for git clone (token or ssh)"
  type        = string
  default     = "token"
}

variable "custom_archive_tgz" {
  description = "Base64-encoded custom stack archive (alternative to git clone)"
  type        = string
  default     = ""
}

variable "github_username" {
  description = "GitHub username to invite as collaborator on the infra repo"
  type        = string
  default     = ""
}

# ============================================================================
# Service Account Roles (used by Argo workflows)
# ============================================================================

variable "terraform_sa_role" {
  description = "IAM role ARN for Terraform service account"
  type        = string
  default     = ""
}

variable "ansible_sa_role" {
  description = "IAM role ARN for Ansible service account"
  type        = string
  default     = ""
}

# ============================================================================
# Additional AWS Variables
# ============================================================================

variable "create_dns" {
  description = "Whether to create DNS records (AWS only)"
  type        = bool
  default     = false
}

variable "bootstrap_role" {
  description = "AWS IAM role ARN for bootstrapping (AWS only)"
  type        = string
  default     = ""
}

# ============================================================================
# EKS Variables (AWS defaults, passed but may not be used)
# ============================================================================

variable "eks_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.32"
}

variable "eks_worker_instance_type" {
  description = "EKS worker node instance type"
  type        = string
  default     = "t4g.large"
}

variable "eks_worker_spot_price" {
  description = "EKS worker spot price"
  type        = string
  default     = "0.07"
}

variable "eks_worker_count" {
  description = "EKS worker node count"
  type        = string
  default     = "1"
}

# ============================================================================
# Organization Variables
# ============================================================================

variable "luther_env" {
  description = "Luther environment name"
  type        = string
  default     = "default"
}

variable "org_name" {
  description = "Organization name"
  type        = string
  default     = "luther"
}

# ============================================================================
# Git Repository Variables (from cloud-provision output)
# ============================================================================

variable "repo_clone_ssh_url" {
  description = "SSH clone URL for the infra repository"
  type        = string
  default     = ""
}

variable "repo_name" {
  description = "Name of the infra repository"
  type        = string
  default     = ""
}

variable "repo_org" {
  description = "GitHub organization for the infra repository"
  type        = string
  default     = "luthersystems"
}
