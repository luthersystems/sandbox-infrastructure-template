# InsideOut Inspector Role
#
# This file creates read-only inspector credentials for InsideOut (AWS).
# GCP inspector resources are in gcp-resources.tf.tmpl and only activated
# for GCP deployments via _selectCloudFiles().

locals {
  # AWS inspector role name
  inspector_role_name = "insideout-inspector-${var.project_id}"

  inspector_role_arn      = try(aws_iam_role.insideout_inspector[0].arn, "")
  inspector_role_name_out = try(aws_iam_role.insideout_inspector[0].name, "")
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

  # managed_policy_arns is a read-only reflection of policies attached via
  # aws_iam_role_policy_attachment — ignore it to prevent perpetual drift.
  lifecycle {
    ignore_changes = [managed_policy_arns]
  }
}

resource "aws_iam_role_policy_attachment" "inspector_readonly" {
  count = local.is_aws ? 1 : 0

  role       = aws_iam_role.insideout_inspector[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ============================================================================
# Outputs
# ============================================================================

output "inspector_role_arn" {
  description = "ARN of the InsideOut inspector role (AWS only)"
  value       = local.is_aws ? local.inspector_role_arn : ""
}

output "inspector_role_name" {
  description = "Name of the InsideOut inspector role (AWS only)"
  value       = local.is_aws ? local.inspector_role_name_out : ""
}
