# Deploy-role policy artifacts (issue #147)

**Status: Phase 0 of the staged rollout is LIVE in `../main.tf`** — the deploy
role attaches a customer-managed, **admin-equivalent** `InsideOutWrite` policy
(inline in `main.tf`) in place of the AWS-managed `AdministratorAccess`, plus
the deny-only permission boundary below. Phase 0 is permission-neutral: the
attached body still allows `*` on `*`; only the policy *object* (the identity)
changed, and the role name/ARN is untouched.

Full rationale, options analysis, migration/rollout, blast radius, and test plan:
[`docs/design/least-privilege-deploy-role.md`](../../../docs/design/least-privilege-deploy-role.md).

| File | Status | What it is |
|---|---|---|
| `insideout-deploy-boundary.json` | **LIVE (Phase 0)** — attached as the role's `permissions_boundary` via `aws_iam_policy.insideout_deploy_boundary` in `../main.tf` | Defense-in-depth **permission boundary** (deny-only): `Allow *` minus the provably out-of-scope surface (Organizations, Account/Billing, IAM-user/credential creation, security-monitoring teardown). A strict superset of real deploy usage → non-enforcing for any real deploy. |
| `insideout-write.json` | **PLACEHOLDER — NOT attached** (Phase-2 target; surfaced only as an unused output by `../least_privilege_scaffold.tf`) | The derived scoped `InsideOutWrite` deploy policy body: a per-service allowlist covering every AWS service the composer can provision, plus bounded IAM + `iam:PassRole` (scoped by `iam:PassedToService`). Phase 2 narrows the live admin-equivalent body down to this. |

## `insideout-write.json` is a placeholder — do not hand-maintain, do not attach as-is

- **Generator-owned.** The real `insideout-write.json` must be **generated from
  `insideout-terraform-presets/pkg/composer/iam_actions.go`** (the same metadata
  that already drives the deploy permission preflight), so the policy and the
  preflight cannot drift as components are added. See the design doc §4.1 and the
  drafted presets-side generator ticket. The service allowlist here was derived
  by hand from that metadata **only as a stand-in** until the generator lands.
- **The service list is `AWSIAMActions` create-only seed + a transitive-apply
  delta.** The composer's per-component actions are representative *create* verbs
  (enough to fail the preflight fast); a real `apply`/`destroy` needs the full
  `Describe/Get/List/Modify/Delete/Tag` lifecycle — hence `<service>:*` — plus
  transitive services (`autoscaling`, `ecr`, `sns`, `events`, `tag`, …) that
  never appear in the create-only seed. That delta is confirmed empirically in
  the **shadow / CloudTrail phase** before enforcement (design doc §8.2).
- **Attaching it requires the staged rollout + broad apply testing** in the
  design doc (§8 migration, §10 test plan) — plus the §6(b) preflight companion
  change (`iam:CreatePolicyVersion` / `iam:TagPolicy`) so the bootstrap
  credential can *update* this customer-managed policy on re-provision.
  Attaching a too-tight grant breaks every customer deploy — worse than the
  status quo.
- **Editing `insideout-deploy-boundary.json` is a live change** (it is
  `file()`-read into the attached boundary policy). Keep it deny-only; any new
  Deny must be provably outside real deploy usage (§4 option 3).
