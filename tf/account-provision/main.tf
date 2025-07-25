data "aws_organizations_organization" "org" {
  provider = aws.org-creator
}

# list all OUs under the root
data "aws_organizations_organizational_units" "ous" {
  parent_id = data.aws_organizations_organization.org.roots[0].id

  provider = aws.org-creator
}

locals {
  ou_map = { for ou in data.aws_organizations_organizational_units.ous.children :
    ou.name => ou.id
  }

  # fall back to the root id when your lookup name isn't there
  resolved_parent_id = lookup(
    local.ou_map,
    var.parent_ou_name,
    data.aws_organizations_organization.org.roots[0].id
  )
}

module "luthername_org" {
  source = "github.com/luthersystems/tf-modules.git//luthername?ref=v55.13.4"

  luther_project = var.short_project_id
  aws_region     = var.aws_region
  luther_env     = var.luther_env
  org_name       = var.org_name
  component      = "account"
  resource       = "cust"
}


# Create a new AWS Organization account
resource "aws_organizations_account" "new" {
  name                       = var.account_name
  email                      = var.account_email
  parent_id                  = local.resolved_parent_id
  iam_user_access_to_billing = var.billing_access # "ALLOW" or "DENY"
  role_name                  = var.account_bootstrap_role_name

  # ignore if role_name drift to allow existing bootstrap-> admin swap
  lifecycle {
    ignore_changes = [role_name, parent_id]
  }

  provider = aws.org-creator

  tags = module.luthername_org.tags
}

# terraform SA account can already assume all other roles.

output "account_id" {
  value = aws_organizations_account.new.id
}

output "account_bootstrap_role_name" {
  value = var.account_bootstrap_role_name
}

resource "local_file" "account_setup_tfvars" {
  content = templatefile("${path.module}/account_setup.auto.tfvars.json.tftpl", {
    account_id = aws_organizations_account.new.id
  })

  filename = "${path.module}/../auto-vars/account_setup.auto.tfvars.json"
}
