# Deploy-role policy artifacts (issues #147, #194)

The design, the rollout and the test plan are in
[`docs/design/least-privilege-deploy-role.md`](../../../docs/design/least-privilege-deploy-role.md).

| File | Made by | Used by |
|---|---|---|
| `insideout-deploy-boundary.json` | hand, deny-only | Both deploy roles, as their permission boundary (`../main.tf`, `../../cloud-provision/aws-resources.tf.tmpl`). Live: a change here changes every project on its next apply. |
| `insideout-write.json` | `scripts/policygen.sh` | The scoped `InsideOutWrite` body. `tf/cloud-provision` attaches it to the terraform role when `deploy_policy_mode = "scoped"`. |
| `insideout-workload-boundary.json` | `scripts/policygen.sh` | The boundary on every role the composed stack makes in scoped mode (`<stack_project>-workload-boundary`). |
| `policygen-report.json` | `scripts/policygen.sh` | Review aid: the services per preset, the extra services, and the write policy's statement names in order (the policy has no Sids, to fit the IAM size limit). |
| `extra-services.txt` | hand | Services the template's own Terraform needs outside the presets. `scripts/policygen.sh` passes it with `-extra-services`. |

## The generated files

- Do not edit them. Run `scripts/policygen.sh` and commit the result. CI runs
  `scripts/policygen.sh -check` and fails when they differ from the generator.
- The generator is `cmd/policygen` of luthersystems/insideout-terraform-presets
  at `PRESETS_REF` in `scripts/policygen.sh`. Bump it with the presets version
  reliable composes with, so the policy covers what the stack can create.
- The files hold Terraform template placeholders. `tf/cloud-provision` fills
  them with `templatefile()`:

| Placeholder | Value |
|---|---|
| `${project}` | `stack_project`, the composer project name (`io-<session>`) |
| `${workload_boundary_arn}` | ARN of `<stack_project>-workload-boundary` (path `/`) |
| `${deploy_role_arn}` | ARN of `<short_project_id>-luther-terraform` |
| `${deploy_policy_arn}` | ARN of `<short_project_id>-luther-terraform-deploy` |

## Scoped mode

| Item | Value |
|---|---|
| Switch | `deploy_policy_mode = "scoped"` and `stack_project`, sent by reliable through ui-core in `common.auto.tfvars.json`. The default is `admin`. |
| IAM the stack may write | Roles, policies and instance profiles under `/insideout/<stack_project>/`. A role must carry the workload boundary. |
| Composed stack input | `tf/auto-vars/iam_scope.auto.tfvars.json`: `iam_scope = {path, permissions_boundary}`. The presets put their IAM there. |
| Denied | Changes to the terraform role, its deploy policy and the workload boundary. |

Limits:

- Custom-stack sequence only. vm-provision and k8s-provision make roles off
  the project path, so the scoped policy refuses them.
- The composed archive must come from a presets version that declares the
  `iam_scope` root variable (luthersystems/insideout-terraform-presets#946).
- Moving a project to scoped mode replaces the stack's preset roles (new path
  and boundary). The workload boundary exists whenever `stack_project` is set,
  so a project moved back to admin keeps it while its roles still use it.
