# ─────────────────────────────────────────────────────────────────────────────
# Least-privilege deploy role — SCAFFOLD ONLY (issue #147). NOT ENFORCED.
#
# This file does NOT change how the deploy role is authorized. The live
# attachment `aws_iam_role_policy_attachment.admin` in main.tf still attaches
# arn:aws:iam::aws:policy/AdministratorAccess. Here we only surface the derived
# least-privilege policy artifacts as (unused) Terraform outputs so they are
# version-controlled, diffable, and Terraform-consumable — ready to wire once
# the staged rollout + broad apply-test plan in
# docs/design/least-privilege-deploy-role.md is executed.
#
# Deliberately inert:
#   * no aws_iam_policy / aws_iam_role_policy_attachment / permissions_boundary
#   * only `file()` reads + `output` blocks — creates NO AWS resource
#
# The JSON bodies under ./policies/ are GENERATOR-OUTPUT PLACEHOLDERS. The real
# InsideOutWrite policy is emitted from composer metadata
# (insideout-terraform-presets/pkg/composer/iam_actions.go — see the drafted
# presets generator ticket) so it stays in lockstep with the set of supported
# components. Do not hand-maintain them long-term, and do not attach either body
# without the migration (§6) + test plan (§8) in the design doc.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # Derived least-privilege deploy policy (service allowlist + bounded IAM).
  insideout_write_policy_json = file("${path.module}/policies/insideout-write.json")

  # Defense-in-depth permission boundary (deny-only cap; strict superset of use).
  insideout_deploy_boundary_json = file("${path.module}/policies/insideout-deploy-boundary.json")
}

output "insideout_write_policy_scaffold" {
  description = "SCAFFOLD (#147, NOT attached): derived least-privilege InsideOutWrite deploy policy body. See docs/design/least-privilege-deploy-role.md."
  value       = local.insideout_write_policy_json
}

output "insideout_deploy_boundary_scaffold" {
  description = "SCAFFOLD (#147, NOT attached): defense-in-depth deploy permission-boundary body (deny-only). See docs/design/least-privilege-deploy-role.md."
  value       = local.insideout_deploy_boundary_json
}
