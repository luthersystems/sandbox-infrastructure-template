# Least-privilege deploy role: Phase 1 runbook (record the actions)

Runbook for Phase 1 of
[#147](https://github.com/luthersystems/sandbox-infrastructure-template/issues/147)
([design doc](least-privilege-deploy-role.md) §8.2). Phase 0 put both
customer-account deploy roles on the customer-managed, admin-equivalent
`InsideOutWrite` policy and the deny-only boundary. Phase 1 records which AWS
actions those roles actually call during real deploys and compares them with
the narrower policy Phase 2 will attach. Phase 2 does not start until the
acceptance rule at the end of this page holds.

The roles:

| Role | Name | Runs |
|---|---|---|
| `bootstrap_role` | `<short_project_id>-<region code>-<env>-<org>-account-admin-0` (`tf/account-setup`) | `cloud-provision` |
| `terraform_role` | `<short_project_id>-luther-terraform` (tf-modules `aws-platform-ui-bootstrap`) | `vm-provision`, `k8s-provision`, `custom-stack-provision` |

`…-account-admin-0` exists only on an account Luther provisions
(`account-provision`, `account-setup`). On an account the customer connects,
`bootstrap_role` is the role they connect with. The test account below is
connected that way: the harness connects with
`arn:aws:iam::031780745048:role/platform-test-admin` (reliable devtools'
default), which has AdministratorAccess and no boundary, and other harness
runs use it too. So on platform-cust3:

- `terraform_role` is on Phase 0 and is audited per matrix session.
- `bootstrap_role` is audited as `platform-test-admin`. That records what
  `cloud-provision` calls, mixed with whatever else used the role in the
  window, so its gate result is a list to explain, not a pass or fail.
  Accepting Phase 2 for `…-account-admin-0` needs the M1 and M2 rows run once
  more on a Luther-provisioned account, audited by its `-account-admin-0` ARN.

## 1. Before the first run

1. **Trail.** The test account is platform-cust3 (`031780745048`), where the
   headless deploy harness deploys. ui-infrastructure
   `platform-cust3/deploy_audit_trail.tf` adds a multi-region trail
   `insideout-deploy-audit` with management events (read and write), S3 object
   calls (reads and writes) and Lambda invokes, to bucket
   `luther-cust3-deploy-audit-trail-031780745048` (us-west-2, versioned, kept
   365 days). The bucket policy refuses the audited roles any delete, object
   write or change to the bucket's policy, lifecycle or versioning.
   Before you merge that PR, check whether the account already has a trail that
   covers these roles (an organization trail, for example):

   ```bash
   aws_jump platform-cust3 admin
   aws cloudtrail describe-trails --include-shadow-trails --region us-west-2
   ```

   If an organization trail with management events exists, read it instead
   (step 3, with `-bucket <its bucket>` and
   `-s3-prefix AWSLogs/<org-id>/031780745048`) and do not add a second trail:
   a second copy of management events is charged. Otherwise merge the PR; the
   merge applies `platform-cust3` (it maps to the `test` environment). Events
   before the trail starts logging are not in the bucket; `-source lookup`
   reads the last 90 days of management events without it.
2. **Template ref.** Deploys must use a `SandboxTemplateRef` with Phase 0
   (reliable `tf_start.go`, `500f156` or later), so `terraform_role` (and,
   on a Luther-provisioned account, `…-account-admin-0`) holds
   `InsideOutWrite` and the boundary. Note the ref; it goes in the results.
3. **Tool.** `iamaudit` lives in insideout-terraform-presets (`cmd/iamaudit`,
   package `pkg/iamaudit`), next to the composer metadata the allowlist is
   generated from. Build it at the commit you will record:

   ```bash
   PRESETS=~/src/insideout-terraform-presets   # your checkouts
   SIT=~/src/sandbox-infrastructure-template
   go build -C "$PRESETS" -o /tmp/iamaudit ./cmd/iamaudit
   git -C "$PRESETS" rev-parse --short HEAD   # record it
   ```

4. **Reader.** The audit reads the trail bucket (`s3:ListBucket`,
   `s3:GetObject`) or event history (`cloudtrail:LookupEvents`). Run it after
   `aws_jump platform-cust3 admin`. It makes no write.

## 2. The deploy matrix

Run on staging with the headless harness (reliable `docs/DEVTOOLS_E2E.md`),
which deploys to platform-cust3. Each row is a separate session, so each makes
its own `-luther-terraform` role; the audit selects those by their short
project ids.

| # | What | How | Why |
|---|---|---|---|
| M1 | Bootstrap only | `$DT flow deploy-e2e --bootstrap-only` | `bootstrap_role`'s surface (`cloud-provision`) |
| M2 | Representative stack: VPC, EKS and node group, RDS, ALB, S3, KMS | `$DT flow deploy-e2e --from-session <template session with that stack>` (or `--stack-file`) | Design doc §10 item 1 |
| M3 | Change M2 | Change a config value (instance size, node count), deploy the new version: `$DT tf start <session> --version N+1` | `Modify*`/`Update*` actions |
| M4 | Drift check on M2 | The management drift check (insideout-test MCP `tfdrift`) | Refresh-only plan: `Describe*`/`Get*`/`List*` |
| M5 | Destroy M2, apply again, destroy | insideout-test MCP `tfdestroy`, then `tf start`, then `tfdestroy` | §10 item 2; `Delete*` actions are seen only on destroy |
| M6 | One deploy per component family, each applied, re-planned and destroyed | as M2, one template session per family | §10 item 3: every service in the allowlist |
| M7 | A reverse import into a deployed session | the staging import flow (`/api/import/runs`) | the `aws.imported` provider's calls |

The families for M6 cover every AWS key in presets `pkg/composer/iam_actions.go`
(`AWSIAMActions`):

- compute: `aws_ec2`, `aws_bastion`, `aws_ecs`, `aws_lambda`, `aws_apprunner`
- data: `aws_rds`, `aws_elasticache`, `aws_dynamodb`, `aws_opensearch`, `aws_msk`, `aws_sqs`, `aws_secretsmanager`
- ML: `aws_sagemaker`, `aws_bedrock`, `aws_bedrock_agent`, `aws_agentcore_gateway`, `aws_kendra`
- CI/CD: `aws_codebuild`, `aws_codepipeline`, `aws_github_actions`
- edge and DNS: `aws_cloudfront`, `aws_waf`, `aws_apigateway`, `aws_route53`, `aws_acm`
- operations and identity: `aws_cloudwatch_logs`, `aws_cloudwatch_monitoring`, `aws_grafana`, `aws_cognito`, `aws_backups`, `aws_s3`, `aws_kms`

Record each run: session id, its `short_project_id` (the prefix of its
`-luther-terraform` role), components, region, job id and status. The audit
selects the matrix's roles by those ids, so a harness run outside the matrix
on the same account, or one on an older template ref, does not mix in. A run
that fails for a reason other than permissions is run again; a run that fails
on permissions is a finding (it should not happen while the policy is
admin-equivalent; check the boundary).

**How long.** Run the whole matrix twice, at least 7 days apart, so the
window covers provider retries, refresh-only plans of week-old stacks and
anything time-based. The window starts at the first deploy of pass 1 and ends
an hour after the last destroy of pass 2 (CloudTrail delivers a log file
within about 15 minutes). Expect at least 14 days.

## 3. Run the audit

Once per role, over the whole window, against the policy Phase 2 will attach
and the boundary. Until the presets generator lands, that policy is this
repo's placeholder `tf/account-setup/policies/insideout-write.json`; after it
lands, the generated artifact.

List every region a matrix stack deployed to, plus us-east-1: IAM, the global
STS endpoint, CloudFront and Route 53 log there.

First check that the record is whole: the trail's selectors are as
Terraform set them (the boundary does not deny `PutEventSelectors`), and no
log file of the window was changed or removed.

```bash
aws cloudtrail get-event-selectors --trail-name insideout-deploy-audit --region us-west-2
aws cloudtrail validate-logs --region us-west-2 \
  --trail-arn arn:aws:cloudtrail:us-west-2:031780745048:trail/insideout-deploy-audit \
  --start-time 2026-12-01T00:00:00Z --end-time 2026-12-16T00:00:00Z
```

Then run the audit. `IDS` is the matrix's short project ids, joined with `|`.

```bash
T=$SIT/tf/account-setup/policies
IDS='a1b2c3d4|e5f6a7b8'   # from runs.md
COMMON=(
  -source s3
  -bucket luther-cust3-deploy-audit-trail-031780745048 -bucket-region us-west-2
  -s3-prefix AWSLogs/031780745048
  -region us-west-2 -region us-east-1 -region us-east-2   # every region used
  -start 2026-12-01T00:00:00Z -end 2026-12-16T00:00:00Z  # the window
  -policy "$T/insideout-write.json"
  -boundary "$T/insideout-deploy-boundary.json"
)
OUT=$SIT/docs/design/least-privilege-phase1/$(date -u +%F)
mkdir -p "$OUT"

/tmp/iamaudit "${COMMON[@]}" \
  -role-regex "^arn:aws:iam::031780745048:role/($IDS)-luther-terraform\$" \
  -json "$OUT/terraform-role.json" > "$OUT/terraform-role.txt"

/tmp/iamaudit "${COMMON[@]}" \
  -role-arn arn:aws:iam::031780745048:role/platform-test-admin \
  -json "$OUT/bootstrap-role.json" > "$OUT/bootstrap-role.txt"
# On a Luther-provisioned account, instead:
#   -role-regex "^arn:aws:iam::<account>:role/($IDS)-[^/]+-account-admin-0\$"
```

Exit status: 0 when the Phase 2 gate passes, 3 when it fails, 1 or 2 on an
error. A run that matched no event of the roles fails the gate: a wrong role
regex, prefix, region or window would otherwise pass with no evidence. To audit a local copy (`aws s3 sync` of the bucket), use `-source file -file
<dir>`; it skips the `CloudTrail-Digest` and `CloudTrail-Insight` folders.
Without a trail, `-source lookup` with the same `-region` list reads
event history (90 days, management events only, slow: 2 calls a second per
region).

What the report holds:

| Field (`.json`) | Meaning |
|---|---|
| `used` | every IAM action the roles called, with calls, errors, first and last seen, the roles and, when the event name differs, the CloudTrail event that mapped to it |
| `used_not_allowed` | used actions the policy does not allow or the boundary denies; `already_refused` when every call failed with an access-denied error |
| `used_scoped` | used actions allowed only by a statement with a Condition or a Resource other than `*`; check each by hand |
| `denied` | used actions refused with an access-denied error |
| `allowed_never_used` | policy patterns no used action matched: drop candidates |
| `unobservable` | patterns CloudTrail cannot show used (`iam:PassRole`, `sts:TagSession`): keep, review by hand |
| `services_beyond_composer_seed` | services used that the composer's create-only seed does not name: the generator's `TransitiveApplyServices` |

`iam:PassRole` has no event of its own, so the tool infers it from the calls
that hand a role to a service (`RunInstances`, `CreateFunction`,
`CreateCluster`, …; the list is `passRoleCallers` in `actionmap.go`) and checks
it against the policy like a used action. Its reason ends "implied by …".

The tool maps CloudTrail names to IAM actions where they differ (CloudWatch's
`monitoring` event source, `tagging` to `tag`, S3 object calls with a
`versionId` to the `*Version` actions, Lambda and CloudFront version
suffixes, S3 calls such as `PutBucketEncryption` that IAM authorizes as
`s3:PutEncryptionConfiguration`, API Gateway's HTTP-verb actions, marked
approximate). The table is `pkg/iamaudit/actionmap.go`; when an action is "not
allowed" though its service is granted, check that table first.

## 4. Where the results go

- Commit `$OUT/*.json` and `*.txt` to this repo under
  `docs/design/least-privilege-phase1/<date>/`, with a `runs.md` beside them:
  the matrix table of step 2 filled in (sessions, jobs, status), the window,
  the regions, the template ref and the iamaudit commit. One PR per audit,
  referencing #147.
- Comment on #147 with the gate result of each role, the
  `used_not_allowed` and `services_beyond_composer_seed` lists and a link to
  the PR.
- Open or update the presets generator issue (design doc §11) with
  `services_beyond_composer_seed` and the drop candidates.

## 5. Acceptance rule for Phase 2

Phase 2 narrows `InsideOutWrite` to policy P only when all of these hold, for
each role, on one audit (`terraform_role` from the platform-cust3 matrix,
`…-account-admin-0` from the Luther-provisioned rerun described under the role table):

1. **Coverage.** Both passes of the matrix ran on Phase 0 roles, every job
   reached success (apply, change, drift check, destroy, re-apply), and every
   AWS key in `AWSIAMActions` was deployed and destroyed at least once.
2. **Gate.** `iamaudit` against P and the boundary exits 0: no
   `used_not_allowed` entry without `already_refused`. Each `already_refused`
   entry is one the deploy tolerated (its job still succeeded); write that
   down in `runs.md`.
3. **Scoped and unobservable.** Each `used_scoped` entry is checked by hand
   against its Condition or Resource. For `iam:PassRole`, every service that
   was handed a role in the matrix (instance profiles to EC2, cluster and node
   roles to EKS, execution roles to Lambda, ECS, App Runner, SageMaker,
   CodeBuild, CodePipeline, Backup, Grafana, RDS monitoring) is in P's
   `iam:PassedToService` list.
4. **Transitive services.** Each `services_beyond_composer_seed` entry is in
   P (through the generator's `TransitiveApplyServices`) or explained in
   `runs.md` as one the roles do not need (an `already_refused` call).
5. **Drop candidates.** An `allowed_never_used` pattern is dropped from P only
   if its service belongs to no component in the catalog; a service that
   belongs to a component stays even if the matrix did not call it.
6. **Fresh.** P is the policy the Phase 2 change attaches, byte for byte, and
   the audit is re-run on that P after any change to the presets, tf-modules
   or this template that adds a resource type.

The §6(b) preflight companion change (`iam:CreatePolicyVersion`,
`iam:TagPolicy`) is already in both preflight lists (#158, reliable#2259), so
it does not gate Phase 2 any more.

## GCP

The GCP mirror (design doc §7) records two identities: the deployment
service account that runs `cloud-provision` (the uploaded key's
`client_email`, or `gcp_deploy_service_account`), GCP's `bootstrap_role`, and
the management service account `insideout-mgmt-<short_project_id>`. Admin Activity audit logs are always on
and kept 400 days; each entry carries the IAM permission checked
(`protoPayload.authorizationInfo[].permission`), so no name mapping is needed:

```bash
gcloud logging read \
  'logName:"cloudaudit.googleapis.com%2Factivity" AND (protoPayload.authenticationInfo.principalEmail:"insideout-mgmt-" OR protoPayload.authenticationInfo.principalEmail="<deployment SA email>")' \
  --project <gcp project> --freshness 30d --format json \
  | jq -r '.[].protoPayload.authorizationInfo[]?.permission' | sort | uniq -c
```

Read calls are in Data Access logs, which are off by default; turn them on
for the test project before the matrix to see them. `iamaudit` does not read
GCP logs yet; compare the list with the custom role's `includedPermissions`
by hand until it does.
