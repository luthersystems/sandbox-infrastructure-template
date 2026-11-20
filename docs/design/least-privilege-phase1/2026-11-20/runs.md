# Scoped-mode shadow runs, platform-cust3, 2026-11-20

These are the first shadow runs (runbook section 2a) with
`deploy_policy_mode = "scoped"` (#195, #197, #198), on the staging harness.
They are a smoke test that comes before the full matrix in the runbook. They
are not a Phase 2 audit: no `iamaudit` run, one pass only, and only rows M2
and M5. They are kept here because they found the first missing
permission, and because a matrix run can be compared against them.

## How the numbers were made

- Account `031780745048`, regions us-west-2 and us-east-1 (IAM, global STS).
- `aws cloudtrail lookup-events` reads event history, which holds management
  events only. S3 object calls and Lambda invokes are data events and are
  missing. KMS calls such as `Decrypt` and `GenerateDataKey` are management
  events and are included. The events are filtered to `userIdentity.arn`
  containing `assumed-role/<short_project_id>-luther-terraform/`. The script
  is in the runbook, §3 "Quick check for a scoped run".
- Only the terraform role is counted. On this account `cloud-provision` runs
  as `bootstrap_role`, which is `platform-test-admin` (runbook, role table),
  so its calls are not here.
- `*-used.tsv`: call count, event source, event name. `*-denied.tsv`: the
  refused calls (time, source, name, code, message). The files were made
  with the error-code filter `AccessDenied|Unauthorized`. A recheck with the
  runbook's wider filter (adding `AuthorizationError|Forbidden`) found
  nothing more. The role's other error codes were all expected ones: missing
  resources during destroy, unset S3 bucket settings, and KMS `CreateKey`
  retries ("invalid principals") while a new role propagated.
- These are CloudTrail event names, not IAM actions. `iam:PassRole` has no
  event of its own and shows up only as the denied call that needed it.

## Runs

| Project | Window (UTC) | Template | What ran | Calls | Distinct events | Denied |
|---|---|---|---|---|---|---|
| `2be49a66` | 06:00 to 06:15 | after #195 | the start of a custom-stack apply: VPC, subnets, route tables, NACLs, VPC endpoint, an S3 bucket, a KMS key, SQS, an alarm. No EKS or RDS call in the window. | 152 | 61 | 0 |
| `727f7bef` | 06:20 to 07:00 | after #197, before #198 | stack apply failed at `rds:CreateDBInstance`, then a partial destroy (no `DeleteCluster` or `DeleteVpc` in the window) | 1,275 | 156 | 1 |
| `fa5150df` | 15:55 to 18:15 | `a468b1d` (#198) | VPC, EKS cluster and node group with add-ons and pod identity, RDS with a read replica, ALB, NAT, S3, KMS, logs; applied and destroyed | 1,868 | 168 | 0 |

The two M2 runs:

| Project | Session | Presets (stack / policy) | Apply | Destroy |
|---|---|---|---|---|
| `727f7bef` | `sess_v2_IgyIO07RgGrT` (`io-igyio07rggrt`) | v0.15.0 / v0.15.0 | Failed: `AccessDenied` at RDS create | Success (`ignore_drift=1`) |
| `fa5150df` | `sess_v2_T5UHPzVbUOKl` (`io-t5uhpzvbuokl`) | v0.15.2 / v0.15.1 | Success (`ccs-fa5150df-n4p5s`). A first try stopped at the RDS replica name, which presets#956 fixed. | Success on the second try (`dst-fa5150df-56pcs`, `ignore_drift=1`) |

Both runs used the same stack in us-west-2: a private VPC across 2 AZs with 1
NAT, EKS with a node group, RDS with a replica, an ALB, S3, KMS and
CloudWatch Logs. `2be49a66` and `ba077396` were smaller runs earlier the same
day. They deployed and destroyed a bundled stack with no denial; only the
first 15 minutes of `2be49a66` are in the table above.

## The one denial

```
2026-11-20T06:30:20Z rds.amazonaws.com CreateDBInstance AccessDenied
727f7bef-luther-terraform is not authorized to perform iam:PassRole on
role/insideout/io-igyio07rggrt/io-igyio07rggrt-or-prod-luthersystems-insideout-rds-rds0-em
```

The role ending in `-em` is the RDS enhanced-monitoring role. The scoped
policy allowed `iam:PassRole` on `/insideout/<stack_project>/` roles only for
a list of `iam:PassedToService` values. That list already had
`monitoring.rds.amazonaws.com`, the service that assumes the role. But
`CreateDBInstance` with a `MonitoringRoleArn` checks the pass against
`rds.amazonaws.com`, the service the call is made to, and that value was
missing. Presets v0.15.1 (`pkg/policygen` `passedVia`, presets#954) adds
`rds.amazonaws.com`, and this repo picks it up in #198. The `fa5150df` run
deployed on that version with no denial.

The lesson for the runbook (acceptance rule 3): the `iam:PassedToService`
value is the service whose API receives the role. Sometimes that is not the
service principal in the role's trust policy.

## Cleanup

Everything left behind by 4 test projects was removed after the runs: the 3
above, and `ba077396` (the other early run; no CloudTrail pull). The removal
covered: 8 IAM roles,
11 policies (including the 3 `io-*-workload-boundary` policies), 4 tfstate
buckets, 10 log groups, and the 4 tfstate KMS keys (scheduled for deletion on
2026-11-27). A listing afterwards found no EKS, RDS, ELBv2, NAT, EIP or
non-default VPC in either region.

The leftovers are worth noting for the matrix. Two of them come from a normal
destroy and are not cleanup misses:

- `<stack_project>-workload-boundary` is made by cloud-provision, not by the
  stack, so a stack destroy leaves it. That is on purpose (#195: it exists
  whenever `stack_project` is set).
- EKS Container Insights and RDS log groups are made by the services, not by
  Terraform, so a destroy does not remove them. This is a presets leak,
  tracked in presets#957.

The deploy role, inspector role, tfstate bucket and key are per-project
bootstrap. They stay until the project itself is deleted.

## Not covered

- Rows M1, M3, M4, M6 and M7, and the second pass 7 days later.
- vm-provision and k8s-provision.
- The `iamaudit` gate against the trail bucket.
