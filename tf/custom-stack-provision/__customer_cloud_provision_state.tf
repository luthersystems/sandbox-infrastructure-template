# AWS: Read remote state from S3 (only used for AWS deployments)
# Skipped when skip_remote_state=true (e.g. plan-only on new projects with no state yet)
data "terraform_remote_state" "cloud_provision" {
  count   = var.cloud_provider == "aws" && !var.skip_remote_state ? 1 : 0
  backend = "s3"

  config = {
    workspace_key_prefix = var.short_project_id
    bucket               = var.bootstrap_state_bucket
    region               = var.bootstrap_state_region
    key                  = format("%s/bootstrap/terraform_%s.tfstate", var.bootstrap_state_env, var.short_project_id)
    kms_key_id           = var.bootstrap_state_kms_key_id
  }
}

locals {
  # AWS: Get role ARN from remote state, fall back to var when skipped
  terraform_role_arn = var.cloud_provider == "aws" && !var.skip_remote_state ? data.terraform_remote_state.cloud_provision[0].outputs.terraform_role : var.terraform_sa_role

  # Domain is available in both clouds (passed via tfvars)
  domain = var.cloud_provider == "aws" && !var.skip_remote_state ? data.terraform_remote_state.cloud_provision[0].outputs.domain : var.domain
}

# Domain variable for GCP (AWS gets it from remote state)
variable "domain" {
  description = "Domain name for the deployment"
  type        = string
  default     = ""
}
