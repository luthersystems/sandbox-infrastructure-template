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
  description = "Repository role for the invited GitHub collaborator: pull (default, read only), triage, push, maintain, admin, or an organization's custom repository role. Applies to new projects only (see the collaborator resource in repo.tf)."
  type        = string
  # Read only (#160). The -infra repo is an output copy of the deployed state:
  # deploys push snapshots as the platform (the repo's deploy key, or the
  # GitHub App token when create_infra_deploy_key is false), not as this user.
  # With push or more, a customer could push commits that the next deploy merges
  # into the deployed state, and with admin also change settings, deploy keys or
  # protection. A customer who wants a change asks the platform to make it.
  default = "pull"

  validation {
    condition     = trimspace(var.collaborator_permission) != ""
    error_message = "collaborator_permission must not be empty."
  }
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

# Set by ui-core for a keyless GCP deploy (ui-core#153): the customer's
# deploy service account. gcp_credentials_b64 is then an external_account
# credential that impersonates it through the platform's deploy workload
# identity pool, and has no client_email to read. Empty for a key deploy.
variable "gcp_deploy_service_account" {
  # A project first deployed with a key keeps its token-creator grants only
  # if this names the same account as that key's client_email: the grants
  # carry prevent_destroy, so a different account fails the plan rather than
  # replace them.
  description = "GCP service account a keyless (workload identity) deploy impersonates; empty for a key deploy"
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.gcp_deploy_service_account == "" || can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\\.iam\\.gserviceaccount\\.com$", var.gcp_deploy_service_account))
    error_message = "gcp_deploy_service_account must be a user-managed service account email (<name>@<project>.iam.gserviceaccount.com), or empty."
  }
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
  nullable    = false

  validation {
    # A principal set of a workload identity pool: the pool's resource path,
    # then the attribute selector (for the platform pools,
    # attribute.aws_role/<assumed-role ARN>).
    condition     = var.inspector_wif_principal_set == "" || can(regex("^principalSet://iam\\.googleapis\\.com/projects/[0-9]+/locations/global/workloadIdentityPools/[a-z0-9-]{4,32}/[^[:space:]]+$", var.inspector_wif_principal_set))
    error_message = "inspector_wif_principal_set must be empty or a workload identity pool principal set: principalSet://iam.googleapis.com/projects/<number>/locations/global/workloadIdentityPools/<pool>/<attribute>."
  }
}

# ============================================================================
# Deploy policy (#147, #194)
# ============================================================================

# Set by reliable through ui-core in tf/auto-vars/common.auto.tfvars.json.
variable "deploy_policy_mode" {
  description = "Deploy policy on the durable terraform role (AWS): admin (default) attaches the admin-equivalent body; scoped attaches the policy generated from the presets (tf/account-setup/policies/insideout-write.json). Scoped is for the custom-stack sequence only."
  type        = string
  default     = "admin"
  nullable    = false

  validation {
    condition     = contains(["admin", "scoped"], var.deploy_policy_mode)
    error_message = "deploy_policy_mode must be admin or scoped."
  }
}

# The composer's project name (io-<session>), which the presets put in their
# IAM path and Project tag. The scoped policy allows IAM writes only under
# /insideout/<stack_project>/ and only on resources tagged with it.
variable "stack_project" {
  description = "Composer project name of the custom stack (io-<session>). Required when deploy_policy_mode is scoped."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.stack_project == "" || can(regex("^[A-Za-z0-9+=,.@_-]{1,40}$", var.stack_project))
    error_message = "stack_project must be empty or 1 to 40 characters of letters, digits and +=,.@_-."
  }
}

# Written by this stage into tf/auto-vars/iam_scope.auto.tfvars.json in scoped
# mode, for the composed custom stack. Declared here because every stage loads
# tf/auto-vars.
variable "iam_scope" {
  description = "Not used in this stage; written for custom-stack-provision"
  type        = any
  default     = null
}
