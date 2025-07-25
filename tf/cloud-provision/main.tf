locals {
  domain_parts      = split(".", var.domain)
  base_domain_parts = slice(local.domain_parts, 1, length(local.domain_parts))
  base_domain       = join(".", local.base_domain_parts)
  admin_role_name   = "${var.short_project_id}-luther-terraform"
  admin_role_arn    = module.bootstrap.admin_role
}

module "bootstrap" {
  source = "github.com/luthersystems/tf-modules.git//aws-platform-ui-bootstrap?ref=v55.13.4"

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
  count = var.create_dns ? 1 : 0

  provider = aws.platform-account
  name     = local.base_domain
}

resource "aws_route53_record" "subdomain_ns" {
  count = var.create_dns ? 1 : 0

  provider = aws.platform-account
  zone_id  = data.aws_route53_zone.parent[0].zone_id
  name     = var.domain
  type     = "NS"
  ttl      = 300
  records  = module.bootstrap.aws_route53_zone_name_servers
}

output "terraform_role" {
  value = local.admin_role_arn
}

output "domain" {
  value = module.bootstrap.domain
}

output "project_id" {
  value = var.project_id
}
