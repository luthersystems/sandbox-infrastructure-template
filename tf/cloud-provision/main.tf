locals {
  is_aws            = var.cloud_provider == "aws"
  is_gcp            = var.cloud_provider == "gcp"
  domain_parts      = split(".", var.domain)
  base_domain_parts = slice(local.domain_parts, 1, length(local.domain_parts))
  base_domain       = join(".", local.base_domain_parts)
  admin_role_name   = "${var.short_project_id}-luther-terraform"
  admin_role_arn    = local.is_aws ? module.bootstrap[0].admin_role : ""
}

# Cloud-specific resources (AWS bootstrap, GCP tfstate bucket, inspector roles)
# are in aws-resources.tf.tmpl and gcp-resources.tf.tmpl respectively.
# Only the active cloud's template is copied into place by _selectCloudFiles().

# ============================================================================
# Shared Outputs
# ============================================================================

output "project_id" {
  value = var.project_id
}

output "cloud_provider" {
  description = "Cloud provider used for this deployment"
  value       = var.cloud_provider
}
