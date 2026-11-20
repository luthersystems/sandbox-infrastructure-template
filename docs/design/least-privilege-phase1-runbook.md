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

   (If `aws_jump` cannot find `platform-cust3`, use
   `credhop --account 031780745048 admin`, as in step 4.)

   If an organization trail with management events exists, read it instead
   (step 3, with `-bucket <its bucket>` and
   `-s3-prefix AWSLogs/<org-id>/031780745048`) and do not add a second trail:
   a second copy of management events is charged. Otherwise merge the PR; the
   merge applies `platform-cust3` (it maps to the `test` environment). Events
   before the trail starts logging are not in the bucket; `-source lookup`
   reads the last 90 days of management events without it.
2. **Template ref.** Deploys must use a `SandboxTemplateRef` (reliable
   `tf_start.go`) with Phase 0, `500f156` or later, so `terraform_role` (and,
   on a Luther-provisioned account, `…-account-admin-0`) holds
   `InsideOutWrite` and the boundary. A shadow run in scoped mode (section 2a,
   `tf/account-setup/policies/README.md`) needs `a468b1d` or later: #195 adds the mode, #197 makes the policy known
   at plan, and #198 adds the RDS pass-role fix. Note the ref; it goes in the
   results.
3. **Tool.** `iamaudit` lives in insideout-terraform-presets (`cmd/iamaudit`,
   package `pkg/iamaudit`), next to the composer metadata the allowlist is
   generated from. Build it at the commit you will record:

   Set `PRESETS` and `SIT` to your checkouts, and record the commit the last
   line prints:

   ```bash
   PRESETS=~/src/insideout-terraform-presets
   SIT=~/src/sandbox-infrastructure-template
   go build -C "$PRESETS" -o /tmp/iamaudit ./cmd/iamaudit
   git -C "$PRESETS" rev-parse --short HEAD
   ```

   The snippets on this page have no inline `#` comments, because a stock
   interactive zsh (no `interactivecomments`) passes `#` and the words after it
   as arguments.

4. **Reader.** The audit reads the trail bucket (`s3:ListBucket`,
   `s3:GetObject`) or event history (`cloudtrail:LookupEvents`). Run it after
   `aws_jump platform-cust3 admin`. If that account name does not resolve in
   your shell helpers, use `credhop --account 031780745048 admin`. It makes
   no write.

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

## 2a. Shadow runs of the scoped policy

A matrix row can also run with the scoped policy on its deploy role, so a
missing permission fails the job at once instead of waiting for the audit.
Set the session's mode before its first deploy (admin bearer, staging).
`admin` in place of `scoped` moves it back:

```bash
$DT session deploy-policy <session> scoped
```

The next deploy sends `deploy_policy_mode=scoped`, and `cloud-provision`
attaches the generated `insideout-write.json` in place of the
admin-equivalent body. A job that fails with `AccessDenied` is a finding: note
the action in `runs.md`, fix the generator in presets
(`pkg/policygen`), and run the row again. A shadow run does not replace the
audit of section 3: it shows only what one stack needs.

If a destroy is refused by the pre-destroy check after a partial apply, run it
with `POST /api/tf/destroy?session_id=<session>&ignore_drift=1`.

After each shadow run, run the quick check in section 3 for its role and
window. The first shadow runs (2026-11-20) are in
[least-privilege-phase1/2026-11-20/runs.md](least-privilege-phase1/2026-11-20/runs.md).

## 3. Run the audit

Once per role, over the whole window, against the policy Phase 2 will attach
and the boundary.

**`terraform_role`.** The policy is `tf/account-setup/policies/insideout-write.json`,
which `scripts/policygen.sh` generates from the presets (#194). It holds
Terraform placeholders (`${project}`, `${deploy_role_arn}`,
`${deploy_policy_arn}`, `${workload_boundary_arn}`; see the policies
`README.md`), and Resource ARNs and conditions match only once they are
filled. Every matrix session has its own project, so a copy filled with one
project's values refuses the others' calls. Do one of these:

- Fill the placeholders with patterns that cover every matrix project:
  `${project}` with `io-*`, the role and policy ARNs with
  `arn:aws:iam::031780745048:role/*-luther-terraform` and
  `arn:aws:iam::031780745048:policy/*-luther-terraform-deploy`, and the
  boundary with `arn:aws:iam::031780745048:policy/io-*-workload-boundary`.
- Or run one audit per project, each with that project's filled copy.

Scoped mode covers the custom-stack sequence only. vm-provision and
k8s-provision make roles off the `/insideout/<project>/` path, so the scoped
policy refuses them (policies `README.md`, "Limits"). Gate `terraform_role`
on the custom-stack sessions of the matrix. List what the vm and k8s stages
called in `runs.md` as known gaps. Do not count those calls against the gate.

**`bootstrap_role`.** Its Phase 2 policy is a separate, smaller subset
(design doc §8.3), and nothing generates it yet. Until something does, audit
it against `insideout-write.json` only to get the list of used actions. Its
gate result is a list to explain, not a pass or fail.

List every region a matrix stack deployed to, plus us-east-1: IAM, the global
STS endpoint, CloudFront and Route 53 log there.

First check that the record is whole. Three things must hold:

- The trail logged the whole window: no `StopLogging` call in it.
- Its selectors are as Terraform set them. The boundary does not deny
  `PutEventSelectors`.
- Log file validation is on, and no log file of the window was changed or
  removed. `validate-logs` needs validation on: without it there are no
  digests to check, and a gap goes unseen.

```bash
aws cloudtrail get-trail-status --name insideout-deploy-audit --region us-west-2
aws cloudtrail describe-trails --trail-name-list insideout-deploy-audit --region us-west-2 \
  --query 'trailList[].LogFileValidationEnabled'
aws cloudtrail lookup-events --region us-west-2 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=StopLogging \
  --start-time 2026-12-01T00:00:00Z --end-time 2026-12-16T00:00:00Z
aws cloudtrail get-event-selectors --trail-name insideout-deploy-audit --region us-west-2
aws cloudtrail validate-logs --region us-west-2 \
  --trail-arn arn:aws:cloudtrail:us-west-2:031780745048:trail/insideout-deploy-audit \
  --start-time 2026-12-01T00:00:00Z --end-time 2026-12-16T00:00:00Z
```

`IsLogging` must be true. `LogFileValidationEnabled` must be true. The
`StopLogging` lookup must return no events.

Then run the audit. In the snippet:

- `IDS` is the matrix's short project ids from `runs.md`, joined with `|`.
- The `-region` flags list every region the matrix used.
- `-start` and `-end` are the window.
- `T` points at the filled copies of the policies (see above).

```bash
T=$SIT/tf/account-setup/policies
IDS='a1b2c3d4|e5f6a7b8'
COMMON=(
  -source s3
  -bucket luther-cust3-deploy-audit-trail-031780745048 -bucket-region us-west-2
  -s3-prefix AWSLogs/031780745048
  -region us-west-2 -region us-east-1 -region us-east-2
  -start 2026-12-01T00:00:00Z -end 2026-12-16T00:00:00Z
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
```

On a Luther-provisioned account, select the bootstrap role with
`-role-regex "^arn:aws:iam::<account>:role/($IDS)-[^/]+-account-admin-0\$"`
in place of `-role-arn`.

Exit status: 0 when the Phase 2 gate passes, 3 when it fails, 1 or 2 on an
error. A run that matched no event of the roles fails the gate: a wrong role
regex, prefix, region or window would otherwise pass with no evidence. To audit a local copy (`aws s3 sync` of the bucket), use `-source file -file
<dir>`; it skips the `CloudTrail-Digest` and `CloudTrail-Insight` folders.
Without a trail, `-source lookup` with the same `-region` list reads
event history (90 days, management events only, slow: 2 calls a second per
region).

### Quick check for a scoped run

A deploy in scoped mode is the one that can be refused, and a refused call
shows in event history within about 15 minutes. Run this check after each
scoped deploy, before the full audit. It reads event history for one role
and one window and prints the denied calls:

```bash
ROLE=<short_project_id>-luther-terraform
START=2026-11-20T15:55:00Z END=2026-11-20T18:15:00Z
export AWS_RETRY_MODE=adaptive AWS_MAX_ATTEMPTS=10
for region in us-west-2 us-east-1; do
  aws cloudtrail lookup-events --region "$region" \
    --start-time "$START" --end-time "$END" \
    --query 'Events[].CloudTrailEvent' --output json | jq -c '.[] | fromjson'
done >raw.jsonl
jq -r --arg r "$ROLE" 'select(.userIdentity.arn // "" | contains("assumed-role/"+$r+"/"))
  | [.eventSource, .eventName] | @tsv' raw.jsonl | sort | uniq -c | sort -rn >used.tsv
jq -r --arg r "$ROLE" 'select((.userIdentity.arn // "" | contains("assumed-role/"+$r+"/"))
  and (.errorCode // "" | test("AccessDenied|Unauthorized|AuthorizationError|Forbidden")))
  | [.eventTime, .eventSource, .eventName, .errorCode, (.errorMessage // "")] | @tsv' raw.jsonl >denied.tsv
```

The retry settings are there because `LookupEvents` allows 2 calls a second
per region, and a second check run at the same time gets throttled.

`denied.tsv` must be empty. Each line in it is a missing permission, and the
error message names the action. For `iam:PassRole` it names the role too.
The error codes cover the forms AWS services use for a refused call
(`AccessDenied*`, `*Unauthorized*`, SNS's `AuthorizationError`, `Forbidden`).
The check reads management events only, so a refused S3 object call or
Lambda invoke (data events) does not show here. For those, read the trail
bucket: run `iamaudit` with `-source s3`.
The first scoped runs and their results are in
[`least-privilege-phase1/2026-11-20/runs.md`](least-privilege-phase1/2026-11-20/runs.md).

### What the report holds

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
   `iam:PassedToService` list. The value to list is the service whose API
   receives the role, which is sometimes not the principal in the role's
   trust policy. For example, an RDS enhanced-monitoring role trusts
   `monitoring.rds.amazonaws.com`, but `CreateDBInstance` checks the pass
   against `rds.amazonaws.com` (the 2026-11-20 denial, fixed in #198).
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
