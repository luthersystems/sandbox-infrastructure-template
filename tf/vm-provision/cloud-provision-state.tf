data "terraform_remote_state" "cloud_provision" {
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
  terraform_role_arn = data.terraform_remote_state.cloud_provision.outputs.terraform_role
  domain             = data.terraform_remote_state.cloud_provision.outputs.domain
}
