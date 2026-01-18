# InsideOut Inspector Role (AWS only)
#
# This role allows the InsideOut service to inspect deployed AWS resources
# with read-only access. It trusts the Terraform service account role,
# which is used by the Oracle portal via a double-hop AssumeRole.

locals {
  inspector_role_name = "insideout-inspector-${var.project_id}"
}

data "aws_iam_policy_document" "inspector_assume" {
  count = local.is_aws ? 1 : 0

  statement {
    sid    = "AllowTerraformSAAssume"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [var.terraform_sa_role]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "insideout_inspector" {
  count = local.is_aws ? 1 : 0

  name                 = local.inspector_role_name
  description          = "Read-only role for InsideOut infrastructure inspection"
  assume_role_policy   = data.aws_iam_policy_document.inspector_assume[0].json
  max_session_duration = 3600 # 1 hour

  tags = {
    Project   = var.project_id
    ManagedBy = "terraform"
    Purpose   = "insideout-inspection"
  }
}

resource "aws_iam_role_policy_attachment" "inspector_readonly" {
  count = local.is_aws ? 1 : 0

  role       = aws_iam_role.insideout_inspector[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

output "inspector_role_arn" {
  description = "ARN of the InsideOut inspector role (AWS only)"
  value       = local.is_aws ? aws_iam_role.insideout_inspector[0].arn : ""
}

output "inspector_role_name" {
  description = "Name of the InsideOut inspector role (AWS only)"
  value       = local.is_aws ? aws_iam_role.insideout_inspector[0].name : ""
}


