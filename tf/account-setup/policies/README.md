# Deploy-role policy artifacts — SCAFFOLD (issue #147)

**Status: PLACEHOLDER. NOT ATTACHED to any IAM role. Not enforced.**

These JSON bodies are the *reviewable, version-controlled artifact* for
replacing `AdministratorAccess` on the customer-account deploy roles with a
scoped least-privilege policy. They are surfaced only as **unused Terraform
outputs** via `../least_privilege_scaffold.tf`. The live attachment in
`../main.tf` (`aws_iam_role_policy_attachment.admin`) still uses
`AdministratorAccess` and is unchanged by this scaffold.

Full rationale, options analysis, migration/rollout, blast radius, and test plan:
[`docs/design/least-privilege-deploy-role.md`](../../../docs/design/least-privilege-deploy-role.md).

| File | What it is |
|---|---|
| `insideout-write.json` | The derived `InsideOutWrite` deploy policy: a per-service allowlist covering every AWS service the composer can provision, plus bounded IAM + `iam:PassRole` (scoped by `iam:PassedToService`). |
| `insideout-deploy-boundary.json` | Defense-in-depth **permission boundary** (deny-only): `Allow *` minus the provably out-of-scope surface (Organizations, Account/Billing, IAM-user/credential creation, security-monitoring teardown). A strict superset of real deploy usage → attachable without breaking a deploy. |

## These are placeholders — do not hand-maintain, do not attach as-is

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
  the **shadow / CloudTrail phase** before enforcement (design doc §6.2).
- **Attaching either body requires the staged rollout + broad apply testing** in
  the design doc (§6 migration, §8 test plan). Attaching a too-tight grant breaks
  every customer deploy — worse than the status quo.
