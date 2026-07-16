module "luthername_admin" {
  source = "github.com/luthersystems/tf-modules.git//luthername?ref=v55.15.2"

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

    dynamic "condition" {
      for_each = var.aws_external_id != "" ? [var.aws_external_id] : []
      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [condition.value]
      }
    }
  }
}

resource "aws_iam_role" "admin" {
  name               = module.luthername_admin.name
  assume_role_policy = data.aws_iam_policy_document.admin_assume_policy.json

  # #147 Phase 0 (design doc §8.1): deny-only permission boundary — a hard cap
  # that removes only provably-out-of-scope surface (Organizations/Billing
  # control plane, IAM users/login credentials, security-monitoring teardown).
  # Strict superset of real deploy usage ⇒ effective permissions of a real
  # deploy are unchanged. Rollback: remove this line and re-apply — it is
  # independent of the policy swap below.
  permissions_boundary = aws_iam_policy.insideout_deploy_boundary.arn

  tags = module.luthername_admin.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# Least-privilege deploy role — Phase 0 (issue #147):
# docs/design/least-privilege-deploy-role.md §8.1 — "swap the role first,
# tighten later". PERMISSION-NEUTRAL by design:
#
#   * InsideOutWrite is a brand-new CUSTOMER-MANAGED policy whose Phase-0 body
#     is admin-equivalent (Allow * on *) — the same effective surface as the
#     AWS-managed AdministratorAccess it replaces. Real deploys behave exactly
#     as today; only the attached policy OBJECT (the identity) changes.
#   * The role name/ARN is unchanged, so every downstream consumer of
#     `bootstrap_role` (auto-vars, cloud-provision assume_role, cached
#     STS/Oracle paths) and the #2243 preflight — which simulates ACTIONS
#     against the role ARN, never a policy name (design doc §6(a)/§6(c)) —
#     keep working across the swap.
#   * Rollback: point aws_iam_role_policy_attachment.admin back at
#     arn:aws:iam::aws:policy/AdministratorAccess and re-apply.
#
# Phase 2 later narrows only the BODY of this policy (an in-place
# CreatePolicyVersion — never a role/ARN change) to the generator-owned
# allowlist kept as ./policies/insideout-write.json (surfaced, unattached, by
# least_privilege_scaffold.tf). Do NOT attach that scoped body yet: enforcement
# is gated on the §8.2 CloudTrail shadow phase and the §6(b) preflight
# companion change (iam:CreatePolicyVersion / iam:TagPolicy).
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_iam_policy" "insideout_write" {
  name        = "${module.luthername_admin.name}-insideout-write"
  description = "InsideOut deploy policy (#147 Phase 0: admin-equivalent body; Phase 2 narrows it to the generated allowlist — see policies/insideout-write.json)."

  # The Phase-0 body is inline and admin-equivalent ON PURPOSE. The checked-in
  # policies/insideout-write.json is the NARROWER generator-output placeholder
  # for Phase 2 — inlining here (instead of file()-ing that JSON) keeps the
  # scoped body un-attached until the shadow/audit phase validates it; wiring
  # it early risks mid-apply 403s (the reliable#2243 failure class).
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AdminEquivalentPhase0"
        Effect   = "Allow"
        Action   = "*"
        Resource = "*"
      }
    ]
  })

  # Deliberately untagged: tagging a policy at create time additionally
  # requires iam:TagPolicy, which is not yet in the bootstrap preflight lists
  # (design doc §6(b) — that companion change gates Phase 2). Untagged,
  # iam:CreatePolicy alone suffices, so a credential that passes today's
  # preflight can apply this change.
}

# Deny-only boundary body (generator-output placeholder, see
# policies/README.md). Deny-only ⇒ non-enforcing for real deploy usage; safe
# to attach in Phase 0 per design doc §4 option 3 / §8.1.
resource "aws_iam_policy" "insideout_deploy_boundary" {
  name        = "${module.luthername_admin.name}-insideout-deploy-boundary"
  description = "Deny-only permission boundary for the InsideOut deploy role (#147 Phase 0 defense-in-depth)."
  policy      = file("${path.module}/policies/insideout-deploy-boundary.json")

  # Untagged for the same §6(b) preflight reason as insideout_write above.
}

resource "aws_iam_role_policy_attachment" "admin" {
  role = aws_iam_role.admin.name
  # #147 Phase 0: the customer-managed InsideOutWrite policy (admin-equivalent
  # body, above) replaces arn:aws:iam::aws:policy/AdministratorAccess.
  policy_arn = aws_iam_policy.insideout_write.arn
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
