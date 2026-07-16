# ─────────────────────────────────────────────────────────────────────────────
# Least-privilege deploy role — Phase-2 TARGET scaffold (issue #147).
#
# Phase 0 (docs/design/least-privilege-deploy-role.md §8.1) is LIVE in main.tf:
# the deploy role now attaches the customer-managed, admin-equivalent
# InsideOutWrite policy (aws_iam_policy.insideout_write) in place of the
# AWS-managed AdministratorAccess, capped by the deny-only permission boundary
# (aws_iam_policy.insideout_deploy_boundary, whose body — the former second
# scaffold output — is consumed live from
# ./policies/insideout-deploy-boundary.json and is therefore no longer
# surfaced here).
#
# This file now carries only the piece that is still NOT enforced: the SCOPED
# Phase-2 policy body ./policies/insideout-write.json — the generator-output
# placeholder that InsideOutWrite's admin-equivalent body will be narrowed to
# (an in-place policy-version update; never a role/ARN change) once the §8.2
# CloudTrail shadow phase and the §6(b) preflight companion change
# (iam:CreatePolicyVersion / iam:TagPolicy) have landed. It stays surfaced as
# an unused output so it remains version-controlled, diffable, and
# Terraform-consumable.
#
# The JSON body is a GENERATOR-OUTPUT PLACEHOLDER: the real artifact is emitted
# from composer metadata
# (insideout-terraform-presets/pkg/composer/iam_actions.go — see the drafted
# presets generator ticket in the design doc §11). Do not hand-maintain it
# long-term, and do not attach it without executing §8 + §10 of the design doc.
# ─────────────────────────────────────────────────────────────────────────────

output "insideout_write_policy_scaffold" {
  description = "SCAFFOLD (#147, Phase-2 target — NOT attached): scoped least-privilege InsideOutWrite deploy policy body. The LIVE Phase-0 body on the role is admin-equivalent; see main.tf and docs/design/least-privilege-deploy-role.md §8."
  value       = file("${path.module}/policies/insideout-write.json")
}
