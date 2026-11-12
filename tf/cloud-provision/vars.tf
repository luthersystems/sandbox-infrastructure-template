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

# Set by ui-core (TF_VAR_adopt_infra_repo) when its GitHub App created the
# repo before this stage runs. See the import block in repo.tf.
variable "adopt_infra_repo" {
  description = "Import the -infra repo that ui-core's GitHub App created, instead of creating it."
  type        = bool
  default     = false
}

# Set to false by ui-core (TF_VAR_create_infra_deploy_key) when its GitHub
# App is on. See the deploy key in repo.tf.
variable "create_infra_deploy_key" {
  description = "Make a write deploy key for git over SSH to the -infra repo. Off when git uses ui-core's GitHub App token."
  type        = bool
  default     = true
}

variable "github_username" {
  description = "GitHub username to invite as collaborator on the infra repo"
  type        = string
  default     = ""
}

variable "vulnerability_alerts" {
  description = "Enable vulnerability alerts on the infrastructure repository"
  type        = bool
  default     = true
}

variable "collaborator_permission" {
  description = "Permission level for the GitHub collaborator (pull, triage, push, maintain, admin)"
  type        = string
  default     = "admin"
}

# ============================================================================
# AWS Variables (required when cloud_provider = aws)
# ============================================================================

variable "aws_region" {
  description = "AWS region (required for AWS deployments)"
  type        = string
  default     = ""
}

variable "bootstrap_state_region" {
  description = "AWS region where the S3 state bucket lives (falls back to aws_region if empty)"
  type        = string
  default     = ""
}

variable "bootstrap_role" {
  description = "AWS IAM role ARN for Terraform (required for AWS deployments)"
  type        = string
  default     = ""
}

variable "aws_external_id" {
  description = "ExternalId for confused-deputy protection when assuming cross-account roles"
  type        = string
  default     = ""
}

# Static access keys: ui-core's alternative to bootstrap_role when the customer
# connects with an access key pair instead of a role ARN. Without these
# declarations the keys were dropped ("The root module does not declare a
# variable named aws_access_key_id") and the provider ran as the runner's own
# IRSA identity (luthersystems/reliable#2461).
variable "aws_access_key_id" {
  description = "AWS access key ID (alternative to bootstrap_role)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "aws_secret_access_key" {
  description = "AWS secret access key (required with aws_access_key_id)"
  type        = string
  default     = ""
  sensitive   = true
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

variable "gcp_impersonate_service_account" {
  description = "Optional GCP service account email to impersonate for steady-state Terraform operations"
  type        = string
  default     = ""
}

# Set by ui-core in tf/auto-vars/common.auto.tfvars.json (ui-core#157): the
# InsideOut oracle's federated identity in the platform workload identity pool
# (insideout-oracle-test or insideout-oracle-prod), for example
# principalSet://iam.googleapis.com/projects/<pool project number>/locations/global/workloadIdentityPools/insideout-oracle-test/attribute.aws_role/<oracle role ARN>.
# When set, it may mint tokens for the GCP inspector service account, so the
# oracle reaches the inspector through Workload Identity Federation with no
# stored key. Empty grants nothing.
variable "inspector_wif_principal_set" {
  description = "Workload identity principal set that may impersonate the GCP inspector service account (empty: none)"
  type        = string
  default     = ""

  validation {
    condition     = var.inspector_wif_principal_set == "" || startswith(var.inspector_wif_principal_set, "principalSet://iam.googleapis.com/")
    error_message = "inspector_wif_principal_set must be empty or start with principalSet://iam.googleapis.com/."
  }
}
