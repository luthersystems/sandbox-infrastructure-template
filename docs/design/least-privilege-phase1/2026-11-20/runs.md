# Shadow runs of the scoped deploy policy, 2026-11-20

Shadow runs (runbook section 2a) of the generated scoped policy on
platform-cust3 (`031780745048`), staging harness. These are not a full matrix
pass: they cover row M2 and its destroy (M5) only.

## Runs

| Run | Session | Short project id | Stack | Template ref | Presets (stack / policy) | Apply | Destroy |
|---|---|---|---|---|---|---|---|
| 1 | `sess_v2_IgyIO07RgGrT` | `727f7bef` | VPC (private, 2 AZ, 1 NAT), EKS and node group, RDS with replica, ALB, S3, KMS, CloudWatch Logs; us-west-2 | before `a468b1d` | v0.15.0 / v0.15.0 | Failed: `AccessDenied` at RDS create | Success (`ignore_drift=1`) |
| 2 | `sess_v2_T5UHPzVbUOKl` | `fa5150df` | Same as run 1 | `a468b1d` | v0.15.2 / v0.15.1 | Success (`ccs-fa5150df-n4p5s`, after a first try that stopped at the RDS replica name, fixed in presets#956) | Success on the second try (`dst-fa5150df-56pcs`, `ignore_drift=1`) |

Two smaller runs earlier the same day (`2be49a66`, `ba077396`) deployed and
destroyed a bundled stack with no denial.

## CloudTrail

Read with `aws cloudtrail lookup-events` (us-west-2 and us-east-1), filtered
to the role `<id>-luther-terraform`.

| Run | Window (UTC) | Calls by the role | Distinct actions | Denied |
|---|---|---|---|---|
| 1 | 06:20 to 07:00 | 1,275 | 156 | 1 |
| 2 | 15:55 to 18:15 | 1,868 | 168 | 0 |

The one denial of run 1:

| Time | Call | Refused action |
|---|---|---|
| 06:30:20Z | `rds:CreateDBInstance` | `iam:PassRole` on the RDS enhanced monitoring role `…-rds-rds0-em` |

RDS takes the monitoring role with `iam:PassedToService=rds.amazonaws.com`,
though the role trusts `monitoring.rds.amazonaws.com`. Fixed in presets
v0.15.1 (`pkg/policygen` `passedVia`, presets#954) and in this repo by #198.

## Clean-up

After the destroys, these were left in the account and deleted by hand:
the deploy and inspector roles and their policies, the workload boundary
policies, the tfstate buckets and KMS keys (bootstrap, kept by destroy by
design), and 10 log groups that AWS made (EKS Container Insights, RDS
postgresql). The log groups are a leak of the presets: presets#957.

## Not covered

- Rows M1, M3, M4, M6, M7, and the second pass 7 days later.
- vm-provision and k8s-provision.
- The `iamaudit` gate against the trail bucket.
