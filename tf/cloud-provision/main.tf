locals {
  is_aws            = var.cloud_provider == "aws"
  is_gcp            = var.cloud_provider == "gcp"
  domain_parts      = split(".", var.domain)
  base_domain_parts = slice(local.domain_parts, 1, length(local.domain_parts))
  base_domain       = join(".", local.base_domain_parts)
  admin_role_name   = "${var.short_project_id}-luther-terraform"
  admin_role_arn    = local.is_aws ? module.bootstrap[0].admin_role : ""
}

# ============================================================================
# AWS Resources (only created when cloud_provider = aws)
# ============================================================================

module "bootstrap" {
  count  = local.is_aws ? 1 : 0
  source = "github.com/luthersystems/tf-modules.git//aws-platform-ui-bootstrap?ref=v55.15.0"

  admin_role_name     = local.admin_role_name
  create_dns          = var.create_dns
  project             = var.short_project_id
  env                 = var.luther_env
  org_name            = var.org_name
  domain              = var.domain
  create_state_bucket = true
  admin_principals    = [var.terraform_sa_role]
  kms_alias_suffix    = format("%s-tfstate", var.short_project_id)

  providers = {
    aws    = aws
    random = random
  }
}

data "aws_route53_zone" "parent" {
  count = local.is_aws && var.create_dns ? 1 : 0

  provider = aws.platform-account
  name     = local.base_domain
}

resource "aws_route53_record" "subdomain_ns" {
  count = local.is_aws && var.create_dns ? 1 : 0

  provider = aws.platform-account
  zone_id  = data.aws_route53_zone.parent[0].zone_id
  name     = var.domain
  type     = "NS"
  ttl      = 300
  records  = module.bootstrap[0].aws_route53_zone_name_servers
}

# ============================================================================
# GCP Resources (only created when cloud_provider = gcp)
# ============================================================================

# GCP bootstrap: Create a GCS bucket for Terraform state
resource "google_storage_bucket" "tfstate" {
  count = local.is_gcp ? 1 : 0

  name          = "${var.short_project_id}-tfstate"
  location      = var.gcp_region
  force_destroy = false

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }
}

# ============================================================================
# Outputs
# ============================================================================

output "terraform_role" {
  description = "AWS IAM role ARN for Terraform (empty for GCP)"
  value       = local.admin_role_arn
}

output "domain" {
  description = "Domain name for the deployment"
  value       = local.is_aws ? module.bootstrap[0].domain : var.domain
}

output "project_id" {
  value = var.project_id
}

output "cloud_provider" {
  description = "Cloud provider used for this deployment"
  value       = var.cloud_provider
}

output "gcp_tfstate_bucket" {
  description = "GCS bucket for Terraform state (GCP only)"
  value       = local.is_gcp ? google_storage_bucket.tfstate[0].name : ""
}
