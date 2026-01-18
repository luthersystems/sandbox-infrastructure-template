# InsideOut Inspector Role
#
# This role allows the InsideOut service to inspect deployed AWS resources
# with read-only access. It trusts the Terraform service account role,
# which is used by the Oracle portal via a double-hop AssumeRole.

locals {
  inspector_role_name = "insideout-inspector-${var.project_id}"
}

data "aws_iam_policy_document" "inspector_assume" {
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
  name                 = local.inspector_role_name
  description          = "Read-only role for InsideOut infrastructure inspection"
  assume_role_policy   = data.aws_iam_policy_document.inspector_assume.json
  max_session_duration = 3600 # 1 hour

  tags = {
    Project   = var.project_id
    ManagedBy = "terraform"
    Purpose   = "insideout-inspection"
  }
}

resource "aws_iam_role_policy_attachment" "inspector_readonly" {
  role       = aws_iam_role.insideout_inspector.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

output "inspector_role_arn" {
  description = "ARN of the InsideOut inspector role"
  value       = aws_iam_role.insideout_inspector.arn
}

output "inspector_role_name" {
  description = "Name of the InsideOut inspector role"
  value       = aws_iam_role.insideout_inspector.name
}


