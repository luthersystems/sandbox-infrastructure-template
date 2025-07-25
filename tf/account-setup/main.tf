module "luthername_admin" {
  source = "github.com/luthersystems/tf-modules.git//luthername?ref=v55.13.4"

  luther_project = var.short_project_id
  aws_region     = var.aws_region
  luther_env     = var.luther_env
  org_name       = var.org_name
  component      = "account"
  resource       = "admin"
}

locals {
  sa_role_arns = concat([var.terraform_sa_role], var.additional_terraform_sa_roles)
}

data "aws_iam_policy_document" "admin_assume_policy" {
  statement {
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = local.sa_role_arns
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "admin" {
  name               = module.luthername_admin.name
  assume_role_policy = data.aws_iam_policy_document.admin_assume_policy.json

  tags = module.luthername_admin.tags
}

resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.admin.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "admin_role_name" {
  value = aws_iam_role.admin.name
}

output "admin_role_arn" {
  value = aws_iam_role.admin.arn
}

resource "aws_iam_service_linked_role" "autoscaling" {
  aws_service_name = "autoscaling.amazonaws.com"
  description      = "Service-linked role for EC2 Auto Scaling"

  lifecycle {
    create_before_destroy = true
  }
}

resource "local_file" "account_setup_tfvars" {
  content = templatefile("${path.module}/cloud_provision.auto.tfvars.json.tftpl", {
    bootstrap_role = aws_iam_role.admin.arn
  })

  filename = "${path.module}/../auto-vars/cloud_provision.auto.tfvars.json"
}
