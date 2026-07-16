# Least-privilege deploy role — replacing `AdministratorAccess` on customer-account roles

Design doc for [luthersystems/sandbox-infrastructure-template#147](https://github.com/luthersystems/sandbox-infrastructure-template/issues/147).

**Status:** proposed / design-first. Nothing in this PR changes how any role is
authorized today (see [§9 Implemented in this PR](#9-implemented-in-this-pr)).

---

## 1. Problem statement

InsideOut provisions cross-account IAM roles **inside the customer's AWS
account**. Today those roles attach the AWS-managed
`arn:aws:iam::aws:policy/AdministratorAccess`. Holding admin in a customer's
account is the single biggest trust ask of the product and the first thing a
security review probes.

The mitigations we already ship reduce **who** can assume the role and **for how
long** — a per-session external ID, a trust policy pinned to the platform
Terraform-SA role, short-lived STS sessions — but they do **not** bound **what
the role can do once assumed**. This doc closes that gap.

### Non-negotiable constraint

A scoped policy that is **too tight breaks every customer deploy** — strictly
worse than the status quo, because a mid-apply `403` can leave orphaned partial
state (this is exactly the [reliable#2243 / Beatloom
incident](#appendix-c-relationship-to-the-existing-preflight) that
`tf/aws-preflight.sh` exists to prevent). A policy that is **too loose defeats
the purpose**. Getting the enumerated surface right — and keeping it right as
components are added — is the whole game, which is why option 2 (generate the
policy from the same metadata that already drives the deploy) is the
recommendation.

---

## 2. Current state — where admin actually lives

There are **two** broad roles in the provisioning path, **both** attaching
`AdministratorAccess`, plus one already-scoped read-only role that stays
unchanged.

### 2.1 The account-setup admin role (`bootstrap_role`) — in THIS repo

`tf/account-setup/main.tf`:

```hcl
resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.admin.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"   # ← #147 target
}
```

- Trust: `terraform_sa_role` (+ `additional_terraform_sa_roles`) with the
  per-session `sts:ExternalId` condition.
- Its ARN is written into `tf/auto-vars/cloud_provision.auto.tfvars.json` as
  `bootstrap_role`.
- **What it actually does:** it is the principal the **`cloud-provision`** stage
  assumes (`tf/cloud-provision/providers-aws.tf.tmpl` →
  `assume_role.role_arn = var.bootstrap_role`). `cloud-provision` creates the
  durable role, the tfstate S3 bucket + KMS key, the inspector role, DNS
  delegation, and the GitHub repo/keys (`repo.tf`).
- **Its true required surface is already enumerated** — `tf/aws-preflight.sh`
  `REQUIRED_ACTIONS` (S3 bucket create/config, KMS key+alias, `iam:*` for the
  role/policy creation, `sts:AssumeRole`, `sts:GetCallerIdentity`). This makes
  the bootstrap role the **low-risk half** of #147: its surface is bounded,
  known, and version-controlled today.

### 2.2 The durable management role (`terraform_role`) — in `tf-modules`

`cloud-provision` instantiates
`github.com/luthersystems/tf-modules.git//aws-platform-ui-bootstrap?ref=v55.15.2`,
whose `admin.tf` creates the durable role and attaches admin **again**:

```hcl
# tf-modules/aws-platform-ui-bootstrap/admin.tf
resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.admin.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"   # ← also #147
}
```

- Named `<short_project_id>-luther-terraform`; exported as the
  `terraform_role` output of `cloud-provision`.
- **What it actually does:** it is the principal that **`vm-provision`,
  `k8s-provision`, and `custom-stack-provision` assume** (each reads
  `terraform_role` from `cloud-provision` remote state — see
  `tf/*/cloud-provision-state.tf` / `__customer_cloud_provision_state.tf`).
  `custom-stack-provision` is where the **reliable/composer-generated customer
  stack** (VPC + EKS + RDS + ALB + S3 + KMS + …) is applied.
- **This is the high-risk half of #147:** it needs the *full multi-service
  provisioning surface* of every composer component, not the bounded bootstrap
  set. Its policy lives in **`tf-modules`, a third repo** — the module today
  exposes **no** `permissions_boundary` or scoped-policy input, so scoping it
  requires a `tf-modules` change + a new `?ref=` tag bump here.

> The module already carries `lifecycle { ignore_changes = [managed_policy_arns] }`
> on the role; the managed-policy **attachment** is a separate resource that
> still reconciles, so swapping it applies cleanly — but existing deployed roles
> won't change until re-provisioned (see [§8 Migration](#8-migration--rollout)).

### 2.3 The inspector role — already scoped, unchanged

`tf/cloud-provision/aws-resources.tf.tmpl` → `aws_iam_role.insideout_inspector`
attaches `arn:aws:iam::aws:policy/ReadOnlyAccess`, `max_session_duration = 3600`,
`prevent_destroy = true`. **Out of scope for #147; do not touch.**

### 2.4 Role map

| Role | Repo / file | Policy today | Assumed by | Required surface |
|---|---|---|---|---|
| account-setup admin (`bootstrap_role`) | this repo · `tf/account-setup/main.tf` | `AdministratorAccess` | `cloud-provision` | **bounded** bootstrap set (already in `aws-preflight.sh`) |
| durable `terraform_role` | `tf-modules/aws-platform-ui-bootstrap/admin.tf` | `AdministratorAccess` | `vm`/`k8s`/`custom-stack` provision (the customer stack) | **broad** — full composer component surface |
| `insideout-inspector` | this repo · `tf/cloud-provision/aws-resources.tf.tmpl` | `ReadOnlyAccess` | Oracle inspector | read-only (unchanged) |

---

## 3. The provisioned surface — what the deploy role must actually be allowed to do

The composer already knows every AWS resource type it emits, and it already
enumerates **per-component IAM actions** for the permission preflight:
`insideout-terraform-presets/pkg/composer/iam_actions.go` —
`AWSIAMActions` (per-`ComponentKey`) + `AlwaysRequiredAWSIAMActions`, surfaced by
`RequiredAWSIAMActions([]ComponentKey)`. **This is the single source of truth
that seeds option 2.**

### 3.1 Service vocabulary (derived from `iam_actions.go`, today)

Collapsing every action in `AWSIAMActions` + `AlwaysRequiredAWSIAMActions` to its
service prefix yields the exact set of AWS services InsideOut can provision:

```
acm            apigateway     apprunner            backup       bedrock
bedrock-agentcore  cloudfront  cloudwatch          codebuild    codepipeline
cognito-idp    dynamodb       ec2                  ecs          eks
elasticache    elasticloadbalancing  es            grafana      iam
kafka          kendra         kms                  lambda       logs
rds            route53        s3                   sagemaker    secretsmanager
sqs            sts            wafv2
```

Component → primary service (abridged; full map in `iam_actions.go`):

| Component key | Service(s) |
|---|---|
| `aws_vpc`, `aws_ec2`, `aws_bastion` | `ec2` |
| `aws_eks`, `aws_eks_nodegroup` | `eks` (+ `ec2`, `iam`, `autoscaling`) |
| `aws_ecs` | `ecs` (+ `ec2`, `iam`, `ecr`) |
| `aws_lambda` | `lambda` (+ `iam`) |
| `aws_apprunner` | `apprunner`, `ec2`, `iam` |
| `aws_sagemaker` | `sagemaker`, `s3`, `cloudwatch`, `iam` |
| `aws_alb` | `elasticloadbalancing` |
| `aws_cloudfront` / `aws_waf` | `cloudfront` / `wafv2` |
| `aws_apigateway` | `apigateway` |
| `aws_rds` / `aws_elasticache` / `aws_dynamodb` | `rds` / `elasticache` / `dynamodb` |
| `aws_s3` / `aws_kms` / `aws_secretsmanager` | `s3` / `kms` / `secretsmanager` |
| `aws_opensearch` | `es` |
| `aws_bedrock`, `aws_bedrock_agent`, `aws_agentcore_gateway` | `bedrock`, `bedrock-agentcore` |
| `aws_kendra` / `aws_sqs` / `aws_msk` | `kendra` / `sqs` / `kafka` |
| `aws_cloudwatch_logs` / `aws_cloudwatch_monitoring` / `aws_grafana` | `logs` / `cloudwatch` / `grafana` |
| `aws_cognito` / `aws_backups` | `cognito-idp` / `backup` |
| `aws_github_actions` | `iam` (OIDC provider) |
| `aws_codebuild` / `aws_codepipeline` | `codebuild` (+`ec2`,`logs`,`s3`,`iam`) / `codepipeline` |
| `aws_route53` / `aws_acm` | `route53` / `acm` |

### 3.2 The critical nuance: the preflight seed is CREATE-only; the deploy policy is broader

`AWSIAMActions` values are **representative create-time actions** — deliberately
just enough for `SimulatePrincipalPolicy` to return `DENIED` fast (e.g.
`aws_rds → rds:CreateDBInstance`). A role that must **`plan` + `apply` +
`destroy`** a stack needs the full `Describe*/Get*/List*/Modify*/Update*/Delete*/Tag*`
lifecycle for each service, plus **transitive services the preset modules pull in
that never appear in the create-only seed**:

- `autoscaling`, `application-autoscaling` — EKS node ASGs, ECS/App Runner scaling
- `ecr` — image repos + pulls for ECS/EKS/App Runner/CodeBuild
- `elasticfilesystem` — EKS EFS CSI (optional modules)
- `sns`, `events` (EventBridge) — CloudWatch alarm actions, Backup, CodePipeline
- `tag` / `resource-groups` — the `Project`-tagging every module applies
- `servicequotas` (read) — some modules pre-check limits

**Design consequence:** hand-enumerating every *action* per service is infeasible
to keep correct (providers add actions constantly; a miss = a broken deploy). The
maintainable unit is the **service** (`<service>:*`), with the **dangerous
surface pulled out into bounded IAM statements + a deny boundary** (§4). The
generator derives the *service allowlist* from `iam_actions.go` for free; the
transitive-service delta and the IAM shape are validated empirically in the
**shadow phase** (§8.2) before enforcement.

---

## 4. Options evaluated

### Option 1 — Hand-curated policy

A checked-in `InsideOutWrite` JSON enumerating services + explicit denies.

- **Pro:** simplest to land; no codegen; fully explicit and reviewable.
- **Con:** **drifts silently.** Every new component (`iam_actions.go` grows
  ~monthly) needs a *separate* manual edit here, and nothing fails CI when
  someone forgets — the failure mode is a customer deploy `403` in the field.
  Two sources of truth (preflight vs. deploy policy) that must agree by
  convention only. Rejected as the steady state; **its JSON shape is reused** as
  the generator's output format and as the interim artifact.

### Option 2 — Generate from composer/preset metadata ✅ RECOMMENDED

Emit the `InsideOutWrite` policy from the **same `iam_actions.go` metadata that
already feeds the preflight**, so the policy and the preflight cannot diverge and
every new component extends both atomically.

- **Pro:** single source of truth; poka-yoke — a new component that adds an
  `AWSIAMActions` entry automatically widens the deploy policy and the preflight
  together; a CI drift-guard makes an unenumerated service fail the build, not
  the customer.
- **Pro:** aligns with the repo design principle *"typed contracts over UI
  reconstruction / static checks enforce design constraints / codify the fix as a
  poka-yoke."*
- **Con:** needs a small generator + a wiring path to inject the JSON into
  `account-setup` (this repo) and the durable-role module (`tf-modules`). Higher
  up-front cost than option 1, repaid immediately in drift-safety.

**Recommendation:** Option 2 for the policy, with Option 3's boundary as
permanent defense-in-depth (they compose: the generated allow-list is the
*grant*, the boundary is the *cap*).

#### 4.1 Generator / pipeline sketch

```
insideout-terraform-presets (owns the vocabulary)
  pkg/composer/iam_actions.go                     ← source of truth (exists)
  pkg/composer/deploy_policy.go        (NEW)      ← DeployPolicyForComponents([]ComponentKey) / AllComponentsDeployPolicy()
                                                     · service allowlist  = { prefix(a) | a ∈ AWSIAMActions ∪ AlwaysRequired } ∪ TransitiveApplyServices
                                                     · bounded IAM statement (CreateRole/PassRole/…) with a PermissionsBoundary + PassedToService condition
                                                     · emits canonical IAM policy JSON
  cmd/policygen               (NEW)               ← writes gen/insideout-write.aws.json (all components = superset)
  pkg/composer/deploy_policy_test.go   (NEW)      ← DRIFT GUARD: every AWS ComponentKey's service prefix ∈ allowlist,
                                                     and RequiredAWSIAMActions ⊆ the generated policy (preflight ⊆ deploy).
                                                     Fails the build on an unenumerated service — mirrors TestAWSIAMActions_CoverAllAWSKeys.
        │ embedded via go:embed / published as gen/insideout-write.aws.json
        ▼
consumers:
  reliable  internal/agentapi/bootstrap_permissions.go   (preflight — already consumes RequiredAWSIAMActions)
  ui-core   aws_iam_preflight.go                          (preflight — same)
  tf-modules  aws-platform-ui-bootstrap                   (NEW input: deploy_policy_json / permissions_boundary_arn) ← durable role
  THIS repo   tf/account-setup                            (attaches the generated policy to the bootstrap role;
                                                            passes boundary + policy through cloud-provision → the module)
```

Injection into Terraform (both roles): the generated JSON is delivered to the
customer archive the same way presets are (embedded → composed → dropped into the
stage), materialized as a `local_file` / `file()` and attached via
`aws_iam_policy` + `aws_iam_role_policy_attachment`, replacing the
`AdministratorAccess` attachment. `account-setup` attaches the **bootstrap
subset** (it only needs the `aws-preflight.sh` surface); `cloud-provision` passes
the **full `InsideOutWrite`** + the boundary ARN into the `aws-platform-ui-bootstrap`
module for the durable role.

**Lockstep guarantee:** the drift-guard test (`RequiredAWSIAMActions ⊆
generated policy`, and every AWS `ComponentKey` service ∈ allowlist) means a
preset PR that adds a component either extends the policy or reddens CI — the
policy can never silently fall behind the components. The generated artifact is
version-controlled (`gen/insideout-write.aws.json`) and re-emitted by
`make regen-imported`-style codegen, never hand-edited.

### Option 3 — Permission boundary + optional SCP (defense-in-depth, ship regardless)

- **Permission boundary** (`aws_iam_role.permissions_boundary`) — a hard *cap*
  on the effective permissions of the deploy role, independent of whatever
  managed/inline policy is attached. A boundary that **Allows `*` and Denies only
  the provably-out-of-scope surface** (Organizations, Account, Billing/Cost,
  IAM-user & credential creation, security-monitoring teardown) is a **strict
  superset of current deploy usage** — so it can be attached **before** the grant
  is tightened, with **zero risk of breaking a deploy**, and it survives even if
  the allow-policy is later widened by mistake. This is the recommended **first
  enforcement step** (§8, folded into Phase 0 alongside the role swap).
- **SCP** (AWS Organizations Service Control Policy) — the same denylist applied
  at the OU level. Only applicable when InsideOut deploys into accounts inside an
  **org we (or the customer) administer**; a no-op for standalone customer
  accounts. Offer as an optional customer-side hardening artifact, not a
  code-path we can universally enforce.

The boundary and the generated `InsideOutWrite` policy **compose**: allow-list =
what the role is granted; boundary = the ceiling it can never exceed. Both should
ship.

---

## 5. Blast radius & non-goals

### 5.1 Blast radius

- **Every customer deploy** runs through these two roles. A missing action in the
  scoped grant surfaces as a mid-`apply` `403` — potentially **after** partial
  resource creation (the reliable#2243 failure mode). This is why enforcement is
  gated behind the shadow phase + broad apply testing, and why the boundary
  (which cannot over-restrict what the deploy actually does) goes first.
- The change touches **three repos** in sequence (presets → tf-modules →
  template), plus the two preflight consumers (reliable, ui-core) for
  consistency.
- `terraform apply` on the durable-role change re-issues the role's policy; the
  role ARN is unchanged, so cached STS/Oracle paths keep working. Existing
  deployed customers are unaffected until re-provisioned (§8).

### 5.2 Non-goals

- **Not** re-scoping the read-only `insideout-inspector` role (already scoped).
- **Not** action-level enumeration per service (infeasible to maintain — §3.2).
- **Not** changing the trust model (external ID / SA pinning / session
  duration) — orthogonal, already shipped.
- **Not** the GCP *implementation* in this PR — but GCP is **no longer excluded
  from the design**: §7 covers the parallel `roles/owner` → scoped-custom-role
  path at design level (the mirror exists — `GCPIAMPermissions` +
  `gcp-preflight.sh`), with the code change tracked as the same follow-up as AWS.
- **Not** flipping any attachment in this PR (design-first — §9).

---

## 6. Congruence with the #2243 permission preflights

This section audits the least-privilege plan against the bootstrap-permission
preflights shipped for [reliable#2243](#appendix-c-relationship-to-the-existing-preflight)
(the Beatloom incident) — the checks that verify the **customer's connecting
credential** *before* a deploy. The plan and the preflights must not fight each
other; the finding is that they mostly already agree, with **one concrete
companion change** required before enforcement.

**The preflight surface — three simulate call-sites, two authored lists.**

| Surface | File | Holds the list? |
|---|---|---|
| reliable → Oracle payload | `reliable/internal/agentapi/bootstrap_permissions.go` :: `bootstrapAWSIAMActions()` | **YES — source of truth #1** (hardcoded) |
| in-container preflight | `sandbox-infrastructure-template/tf/aws-preflight.sh` :: `REQUIRED_ACTIONS` | **YES — source of truth #2** (hardcoded; header declares it the mirror of #1) |
| mars Go binary | `mars/internal/preflight/aws.go` | No — receives the list via `--actions` (passed straight through from `REQUIRED_ACTIONS`) |
| Oracle simulate | `ui-core/portal/oracle/aws_bootstrap_iam_preflight.go` | No — receives it as `requiredActions` (from reliable's payload) |

So the "three preflight lists" are really **two authored lists feeding three
`iam:SimulatePrincipalPolicy` call-sites**. Update the two hardcoded lists and all
three simulate surfaces move together — the mars binary and Oracle hold none of
their own.

### 6(a) The preflight checks ACTIONS, not "is AdministratorAccess attached" — a scoped role is inherently compatible (the friendly case)

All three call-sites evaluate the credential with `iam:SimulatePrincipalPolicy`
over an explicit `ActionNames` list — Oracle at
`aws_bootstrap_iam_preflight.go:81` (`SimulatePrincipalPolicyWithContext(… ActionNames …)`),
the mars binary at `aws.go:210` (`NewSimulatePrincipalPolicyPaginator`), the shell
at `aws-preflight.sh:368` (`aws iam simulate-principal-policy --action-names`), all
fed by `bootstrapAWSIAMActions()`. **None checks whether `AdministratorAccess` is
attached by name.** The only occurrences of the string "AdministratorAccess" in the
entire preflight surface are two lines of **remediation help text**
(`aws-preflight.sh:426`, `aws.go:279` — *"Attach the AdministratorAccess managed
policy … or a policy granting at minimum the N bootstrap actions"*), which are
non-functional.

**Consequence:** whether the bootstrap actions are granted by the AWS-managed
`AdministratorAccess` or by a scoped customer-managed `InsideOutWrite` policy,
`SimulatePrincipalPolicy` returns `allowed` identically. **A scoped deploy role is
inherently preflight-compatible.** The product owner half-remembered this as an
"admin-attached-by-name check"; it is an **action-simulation** check — the friendly
case, needing *no* preflight change for the role swap itself. (Non-blocking
doc-hygiene follow-up: once scoped, those two help-text lines could name
`InsideOutWrite` instead of `AdministratorAccess`.)

### 6(b) The one actionable gap: the bootstrap credential can CREATE + ATTACH the policy, but not version/tag it

The new flow has the **bootstrap credential** create the customer-managed
`InsideOutWrite` policy and attach it to the deploy role during `cloud-provision`,
so that credential must itself hold the IAM actions to do so. Cross-checking both
authored lists:

| Action | reliable `bootstrapAWSIAMActions()` | template `REQUIRED_ACTIONS` | Needed for |
|---|---|---|---|
| `iam:CreateRole` | ✅ `bootstrap_permissions.go:118` | ✅ `aws-preflight.sh:134` | create the role |
| `iam:CreatePolicy` | ✅ `bootstrap_permissions.go:117` | ✅ `aws-preflight.sh:133` | **create** `InsideOutWrite` (first apply) |
| `iam:AttachRolePolicy` | ✅ `bootstrap_permissions.go:116` | ✅ `aws-preflight.sh:132` | attach it to the deploy role |
| `iam:CreatePolicyVersion` | ❌ **absent** | ❌ **absent** | **update** the policy in place on re-provision (Option-2 codegen widens it as components are added) |
| `iam:TagPolicy` | ❌ **absent** | ❌ **absent** | create it **with the `Project` tag** (presets tag every taggable resource; IAM policies are taggable in provider 5.x+) |

**Good news (the compatible half):** the create + attach path — first provision — is
**already fully covered.** `iam:CreatePolicy`, `iam:AttachRolePolicy`, and
`iam:CreateRole` are all present in **both** lists today, so a credential that
passes the #2243 preflight can already stand up `InsideOutWrite` and attach it.

**Actionable companion change (gates Phase-2 enforcement — §8.3).** Before the
least-privilege flow moves from placeholder to enforced, add **`iam:CreatePolicyVersion`**
(and, if the emitted `aws_iam_policy` carries the `Project` tag, **`iam:TagPolicy`**;
plus **`iam:DeletePolicyVersion`** for the 5-version prune terraform does on update)
to **both** source-of-truth lists:

- `reliable/internal/agentapi/bootstrap_permissions.go` — into `bootstrapAWSIAMActions()`,
  after **line 117** (`iam:CreatePolicy`).
- `sandbox-infrastructure-template/tf/aws-preflight.sh` — into `REQUIRED_ACTIONS`,
  after **line 133** (`iam:CreatePolicy`).
- No edit to `mars/internal/preflight/aws.go` or
  `ui-core/portal/oracle/aws_bootstrap_iam_preflight.go` — both consume the list
  from the two above.

**Why it matters:** the whole point of Option 2 is that `InsideOutWrite` *grows*
with the component catalog. Every widening re-applies the policy → terraform calls
`iam:CreatePolicyVersion` (not `CreatePolicy`) against the existing policy ARN.
Without it in the preflight, a customer whose bootstrap credential lacks
`CreatePolicyVersion` **passes preflight on the first deploy and then 403s
mid-apply on the *next* re-provision** — the exact #2243 failure class this
discipline exists to prevent, merely relocated from bucket/role creation to
policy-version creation. **This PR does NOT make that edit** (design-only, §9); it
is captured here and in the PR report as the required companion change.

### 6(c) No `AdministratorAccess` ARN is hard-coded in a way the Phase-0 swap would break

- **Preflight:** nothing branches on a policy ARN or name (see 6(a)). The simulate
  is keyed on the role's **identity ARN** (`PolicySourceArn = bootstrapRoleARN`, or
  the resolved caller ARN), which the Phase-0 policy swap leaves unchanged (the role
  ARN is preserved; only the *attached policy object* changes). The preflight keeps
  passing across the swap.
- **Bootstrap TF:** the live `AdministratorAccess` attachment lives in exactly two
  places — this repo's `tf/account-setup/main.tf:45-47`
  (`aws_iam_role_policy_attachment.admin` → `arn:aws:iam::aws:policy/AdministratorAccess`,
  the `bootstrap_role`) and, for the durable `terraform_role`,
  `tf-modules/aws-platform-ui-bootstrap/admin.tf` (§2.1–2.2). Both are plain
  `aws_iam_role_policy_attachment` resources; Phase 0 replaces the *attached policy
  body*, not the role, so no downstream ARN consumer (the `bootstrap_role` /
  `terraform_role` state outputs, the providers' `assume_role.role_arn`) sees a
  changed value. Nothing pins the *managed-policy* ARN as an identifier anything
  else reads.

**Net:** 6(a) + 6(c) make the Phase-0 identity swap preflight-safe **today**; 6(b)
is the single concrete change the preflight lists need, and it is required before
**Phase 2**, not before Phase 0.

---

## 7. GCP mirror — the parallel least-privilege path

Design-level, included as a **first-class parallel** (the product owner asked
whether a GCP equivalent is needed — it is, and it is the same shape). The AWS plan
above transfers almost one-for-one.

### 7.1 Where the over-privilege lives on GCP

The GCP `cloud-provision` stage grants **`roles/owner`** to the InsideOut
management service account:

```hcl
# tf/cloud-provision/gcp-resources.tf.tmpl
resource "google_project_iam_member" "management_owner" {
  project = var.gcp_project_id
  role    = "roles/owner"
  member  = "serviceAccount:${google_service_account.insideout_management.email}"
}
```

`roles/owner` is the GCP analogue of `AdministratorAccess` — the same "the deploy
identity can do anything in the project" trust ask, and the same thing #147 exists
to bound. (The inspector SA is already scoped to `roles/viewer` + narrow read roles
— the analogue of the read-only inspector role; out of scope, unchanged.)

### 7.2 The Phase-0 → chip-down mirror

Same two-step de-risking as AWS (§8):

- **Phase 0 (GCP):** introduce a brand-new **custom role**
  (`google_project_iam_custom_role`, e.g. `InsideOutDeploy`) whose initial
  `includedPermissions` bundle is behavior-identical to Owner, and bind the
  management SA to it in place of `roles/owner`. **Swap the binding first;** the SA
  identity/email is unchanged, so the downstream token-creator bindings and Oracle
  paths keep working. (There is no project-level equivalent of an AWS permission
  boundary; the nearest cap is an **Organization Policy / IAM deny policy**, offered
  as the optional org-side hardening — the mirror of the AWS SCP, §4 option 3.)
- **Phase 1 (shadow):** GCP has the same auditability — **Cloud Audit Logs (Admin
  Activity)** record the SA's `methodName`s; aggregate them across the deploy matrix
  and diff against the generated permission set.
- **Phase 2 (chip down):** narrow the custom role's `includedPermissions` from the
  Owner-equivalent bundle to the scoped set **generated from the composer's
  `GCPIAMPermissions` / `RequiredGCPIAMPermissions([]ComponentKey)`**
  (`insideout-terraform-presets/pkg/composer/iam_actions.go`) — exactly the metadata
  the GCP bootstrap preflight already consumes (`bootstrapGCPIAMPermissions()` in
  reliable; `gcp-preflight.sh`). Same single-source-of-truth + drift-guard
  discipline as the AWS `InsideOutWrite` generator (§4.1, Option 2).

### 7.3 GCP congruence caveat — the Owner-grant asymmetry

One #2243-related asymmetry to carry forward: the GCP bootstrap preflight already
sets **`requireOwnerGrant=true`** (`bootstrap_permissions.go`) because GCP requires
the *caller* to itself hold Owner in order to grant Owner to another principal, and
`testIamPermissions` cannot verify that. When Phase 2 replaces the `roles/owner`
grant with a bind to a **custom role**, the caller no longer grants Owner — so the
`requireOwnerGrant` assertion becomes **too strict** for the scoped path and must be
revisited in lockstep. The caller then needs custom-role-management permissions —
**`iam.roles.create` / `iam.roles.update`**, which are **absent** from
`bootstrapGCPIAMPermissions()` today (while `resourcemanager.projects.setIamPolicy`,
needed to bind the SA, is already present). This is the **GCP-side companion change**
— the exact analogue of the AWS `iam:CreatePolicyVersion` finding in §6(b).
Design-level; tracked with the AWS one.

---

## 8. Migration / rollout

Staged so no existing customer deploy can break, and so the enumerated set is
validated against **reality** before it is allowed to deny anything.

### 8.1 Phase 0 — new role/policy, still admin (swap the role first) + the non-enforcing boundary

The first phase makes only the changes that carry **no permission change**, so the
risky "which policy object the role uses" swap and the risky "which permissions it
grants" narrowing never land in the same step — ***swap the role first, tighten
later***. Two composable, individually non-breaking moves:

- **New customer-managed `InsideOutWrite` policy, initially admin-equivalent.**
  Introduce `InsideOutWrite` as a brand-new *customer-managed* policy whose initial
  body is behavior-identical to today — `Allow: *` on `*` (the same effective
  surface `AdministratorAccess` grants) — and repoint the deploy roles (the
  account-setup `bootstrap_role` and, via the module, the durable `terraform_role`)
  at it **in place of** the AWS-managed `arn:aws:iam::aws:policy/AdministratorAccess`
  attachment. Because the body is still admin-equivalent, **every real deploy
  behaves exactly as today.** The role ARNs are unchanged (only the attached policy
  *object* changes), so cached STS / Oracle paths keep working (§5.1) and the #2243
  preflight — which simulates *actions* against the role ARN, never a policy name
  (§6(a)/§6(c)) — passes unchanged across the swap. Where a cleaner cutover is
  preferred, the same move can introduce a parallel new *role* and repoint the
  assumers; the policy-swap variant is preferred because it preserves the role ARN.
- **Attach the deny-only permission boundary** (§4 option 3) to the same roles.
  Because the boundary only removes provably-unused surface, effective permissions
  for a real deploy are unchanged → **non-breaking**, immediately truthful in a
  security review ("the role cannot touch Organizations/Billing/IAM-users/CloudTrail"),
  and trivially reverted (detach the boundary). Requires the `tf-modules` module to
  accept a `permissions_boundary_arn` input for the durable role.

Both moves are individually reversible and change **nothing** about what a real
deploy can do — that narrowing is deferred entirely to Phase 2. This **integrates**
the earlier boundary-first idea: the boundary now rides along in Phase 0 as the
companion cap to the identity swap, not as a separate step.

### 8.2 Phase 1 — shadow / audit (validate the enumerated set against reality)

Before the grant is tightened, confirm the option-2 allow-list is a **superset**
of what deploys actually do — now observable directly, since Phase 0 already
attached `InsideOutWrite` (admin-equivalent) to the deploy role, so the shadow diff
is measured against the exact policy body Phase 2 will narrow:

- Enable **CloudTrail** (or reuse the org trail) on the representative test
  account and run the full deploy matrix (§10) + the real component catalog.
- Aggregate the **actual** `eventSource`/`eventName` set the `terraform_role`
  session used (filter by the role's session ARN) and diff it against the
  generated `InsideOutWrite` policy. Every action the role *used* must be
  *allowed*; every service the policy allows that was *never used* is a
  candidate to drop.
- Feed the transitive-service delta (§3.2) back into `TransitiveApplyServices`
  in the generator, so the artifact is empirically grounded, not guessed.
- Keep the drift-guard test green throughout (preflight ⊆ deploy policy).

### 8.3 Phase 2 — chip the `InsideOutWrite` policy down (enforce the scoped grant)

Narrow the body of the already-attached `InsideOutWrite` policy from the Phase-0
admin-equivalent shell to the generated allowlist — `account-setup` gets the
bootstrap subset, the durable-role module gets the full policy. Because the identity
swap happened in Phase 0, **this phase changes only the policy body — never the
role**, so a real deploy's *only* observable change is the tightened grant, isolated
for a clean bisect. The boundary from Phase 0 is still the independent cap.
**Gate:** the §6(b) preflight companion change (`iam:CreatePolicyVersion` /
`iam:TagPolicy`) must already be in both preflight lists before this phase, or a
re-provisioning customer 403s on the policy-version update.

- **Existing customers keep admin until re-provisioned.** Their roles carry
  `ignore_changes = [managed_policy_arns]` on the role resource, and the
  attachment only reconciles on a `cloud-provision` re-apply for that project —
  which is the natural re-provision boundary. Optionally: a one-shot migration
  playbook re-applies `account-setup` + `cloud-provision` for opted-in existing
  projects once the scoped policy has soaked on new ones.

### 8.4 Rollback

- **Phase 0:** repoint the deploy roles back to the AWS-managed `AdministratorAccess`
  attachment and/or detach the boundary (`permissions_boundary_arn = ""` →
  re-apply) — a pure identity/attachment revert, with no permission-narrowing to
  unwind.
- **Phase 2:** restore the `InsideOutWrite` body to admin-equivalent — because the
  role swap already happened in Phase 0, this is a cheap `aws_iam_policy` **version
  revert** (a new policy version), *not* a role/ARN change. Because the boundary is
  independent, a grant rollback still leaves the account protected by the Phase-0
  cap.
- **Operator escape hatch already exists:** `SKIP_AWS_BOOTSTRAP_PREFLIGHT=1`
  bypasses the fail-fast preflight; the analogous field-break lever is reverting
  the attachment via the pinned `?ref=`.

---

## 9. Implemented in this PR

**Design-only** for anything that changes authorization. To keep the option-2
artifact concrete and reviewable *without* touching any live attachment, this PR
adds an **inert scaffold** (the "scaffold the generator behind an unused output"
safe step):

| Path | What it is | Wired in? |
|---|---|---|
| `docs/design/least-privilege-deploy-role.md` | this doc | n/a |
| `tf/account-setup/policies/insideout-write.json` | generator-output **placeholder** — the derived `InsideOutWrite` deploy policy (service allowlist + bounded IAM/PassRole) | **NO** — not attached to any role |
| `tf/account-setup/policies/insideout-deploy-boundary.json` | generator-output **placeholder** — the deny-only permission boundary | **NO** — not attached to any role |
| `tf/account-setup/policies/README.md` | status header: placeholder, not attached, generator-owned | n/a |
| `tf/account-setup/least_privilege_scaffold.tf` | surfaces both JSON bodies as **unused `output`s** so they are version-controlled and Terraform-consumable | inert: `file()` + `output` only — **no resources, no attachment change** |

`aws_iam_role_policy_attachment.admin` in `tf/account-setup/main.tf` **still
attaches `AdministratorAccess`** — unchanged. The scaffold creates **no AWS
resource** and changes **no** effective permission. The JSON bodies are
**placeholders**: the real artifact is emitted by the presets generator (§4.1);
they must not be hand-maintained long-term or attached without executing §8 +
§10 (and the §6(b) preflight companion change).

Verification run for this PR: `terraform fmt`, `terraform validate` (isolated),
`jq` well-formedness on both JSON bodies. No `plan`/`apply` against any
environment.

---

## 10. Test plan (gates Phase 2 enforcement — NOT run in this PR)

1. **Representative stack** — VPC + EKS + RDS + ALB + S3 + KMS composed via
   reliable, deployed headlessly (the `deploy-e2e` / `deploy-headless` harness):
   `plan` + `apply` clean under the scoped `terraform_role`.
2. **Idempotency** — `destroy` → `apply` cycle passes (issue AC).
3. **Broad component sweep** — one deploy per component family (compute, data,
   ML/Bedrock, CI/CD, networking/DNS/ACM) to exercise every service in the
   allowlist + surface transitive gaps.
4. **Preflight parity** — `tf/aws-preflight.sh` (and the `insideout-preflight`
   binary) still pass against the scoped role: the generated policy is a
   superset of `REQUIRED_ACTIONS`. **Plus the §6(b) companion change landed:** both
   bootstrap-action lists carry `iam:CreatePolicyVersion` (and `iam:TagPolicy` if
   the policy is tagged), and a re-provision that *updates* `InsideOutWrite` clears
   the preflight instead of 403-ing on the policy-version write.
5. **Boundary non-regression** — with the Phase-0 boundary attached and admin
   still granted, the same matrix passes unchanged (proves the boundary is a
   superset of real usage).
6. **Drift guard** — presets CI: `RequiredAWSIAMActions ⊆ InsideOutWrite`, every
   AWS `ComponentKey` service ∈ allowlist.
7. **Inspector untouched** — `insideout-inspector` still `ReadOnlyAccess`,
   `prevent_destroy` intact.

---

## 11. Cross-repo split

| Repo | Owns | Change for #147 |
|---|---|---|
| **insideout-terraform-presets** | the action/service **vocabulary** (`pkg/composer/iam_actions.go`) | **NEW** generator (`pkg/composer/deploy_policy.go` + `cmd/policygen`) emitting `InsideOutWrite` JSON from the metadata + drift-guard test. Tracked as **presets#? (draft below)**. |
| **tf-modules** | the durable `terraform_role` (`aws-platform-ui-bootstrap/admin.tf`) | **NEW** inputs `deploy_policy_json` + `permissions_boundary_arn`; replace the `AdministratorAccess` attachment when provided (default keeps admin for back-compat). New tag → bump `?ref=` here. |
| **sandbox-infrastructure-template** (this repo) | the account-setup `bootstrap_role` attachment + the wiring/injection into the module + `aws-preflight.sh` (mirrors the seed today) | scope the bootstrap role; pass the generated policy + boundary through `cloud-provision` into the module; this doc + scaffold. **#147**. |
| **reliable** / **ui-core** | the deploy-time **preflight** (`bootstrap_permissions.go` / `aws_iam_preflight.go`) | already consume `RequiredAWSIAMActions`; keep consuming the *same* metadata so preflight and the deploy policy stay one source of truth (drift guard enforces `preflight ⊆ policy`). **Companion change (§6(b), before Phase 2):** add `iam:CreatePolicyVersion` (+ `iam:TagPolicy`) to `bootstrapAWSIAMActions()` and the mirrored `REQUIRED_ACTIONS`, so the bootstrap credential can *update* the customer-managed `InsideOutWrite` policy on re-provision. |

### Draft presets-side issue (do not post — see PR report)

> **Title:** Generate the `InsideOutWrite` deploy policy from `iam_actions.go` (single source of truth for the least-privilege deploy role)
>
> **Body:** `sandbox-infrastructure-template#147` replaces `AdministratorAccess`
> on the customer-account deploy roles with a scoped `InsideOutWrite` policy. To
> avoid a second source of truth that drifts from the components we support, the
> policy must be **generated from the same `pkg/composer/iam_actions.go` metadata
> that already feeds the permission preflight** (`RequiredAWSIAMActions`).
>
> **Scope:**
> - `pkg/composer/deploy_policy.go` — `DeployPolicyForComponents([]ComponentKey)`
>   / `AllComponentsDeployPolicy()`: service allowlist = service prefixes of
>   `AWSIAMActions ∪ AlwaysRequiredAWSIAMActions` ∪ a small, documented
>   `TransitiveApplyServices` set (autoscaling, application-autoscaling, ecr,
>   sns, events, tag, resource-groups, servicequotas-read, elasticfilesystem);
>   plus a bounded IAM statement (Create/Delete/Get/Tag Role & Policy, instance
>   profiles, OIDC providers) and an `iam:PassRole` statement conditioned on
>   `iam:PassedToService`; emits canonical IAM policy JSON.
> - `cmd/policygen` — writes `gen/insideout-write.aws.json` (all-components
>   superset) for embedding/consumption; wired into the existing codegen make
>   target so it is never hand-edited.
> - `pkg/composer/deploy_policy_test.go` — **drift guard**: every AWS
>   `ComponentKey`'s service prefix is present in the allowlist, and
>   `RequiredAWSIAMActions(allKeys) ⊆` the generated policy (preflight ⊆ deploy).
>   Fails the build on an unenumerated service — mirror
>   `TestAWSIAMActions_CoverAllAWSKeys`. Cite `aws_rds → rds:CreateDBInstance`
>   (create-only seed) as the triggering example for why the deploy policy is a
>   superset of the preflight seed.
> - Mirror for GCP (`GCPIAMPermissions`) as a follow-up.
>
> **Consumers:** `tf-modules/aws-platform-ui-bootstrap` (durable role),
> `sandbox-infrastructure-template/tf/account-setup` + `tf/cloud-provision`
> (bootstrap role + injection), with `reliable`/`ui-core` preflight staying on
> the same metadata. Design: `sandbox-infrastructure-template`
> `docs/design/least-privilege-deploy-role.md`.

---

## Appendix A — derived service allowlist (source for the scaffold JSON)

31 provisioning services (composer `AWSIAMActions` prefixes, minus `iam`/`sts`
which get bounded statements):

```
acm apigateway apprunner backup bedrock bedrock-agentcore cloudfront cloudwatch
codebuild codepipeline cognito-idp dynamodb ec2 ecs eks elasticache
elasticloadbalancing es grafana kafka kendra kms lambda logs rds route53 s3
sagemaker secretsmanager sqs wafv2
```

`+ TransitiveApplyServices` (apply-surface beyond the create-only seed, §3.2):
`autoscaling application-autoscaling ecr sns events elasticfilesystem tag
resource-groups servicequotas(read)`.

## Appendix B — why not just widen the preflight list into the policy?

The preflight (`aws-preflight.sh` `REQUIRED_ACTIONS`,
`RequiredAWSIAMActions`) is intentionally a **minimal create-only tripwire** —
its job is to fail *fast and cheap* before `apply`, not to be complete. Reusing
it verbatim as the deploy policy would under-grant (no `Describe/Delete/Modify/Tag`,
no transitive services) and break `apply`/`destroy`. The correct relationship is
containment, enforced in CI: **`preflight actions ⊆ InsideOutWrite`.**

## Appendix C — relationship to the existing preflight (reliable#2243)

`tf/aws-preflight.sh` was added after the Beatloom incident: an under-privileged
connecting credential passed validation, reached the `cloud-provision` apply, and
`403`'d mid-apply on `s3:CreateBucket` / `iam:CreateRole` **after** `repo.tf` had
already created a GitHub repo + keys — orphaned partial state. That preflight
already enumerates the **bootstrap** surface and delegates to the
`insideout-preflight` Go binary (mars). #147 extends the same
"know-the-required-actions-up-front" discipline from *validating the caller* to
*bounding the role* — and reuses the very same `iam_actions.go` metadata to do
it. **See §6 for the full congruence audit** — action-simulation vs
policy-name (§6(a)), the `iam:CreatePolicyVersion` / `iam:TagPolicy` companion
change (§6(b)), and why the Phase-0 swap is preflight-safe today (§6(c)).
