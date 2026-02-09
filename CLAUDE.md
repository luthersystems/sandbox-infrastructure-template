# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Luther Systems "Mars" infrastructure template. Deploys complete sandbox environments on AWS or GCP using Terraform and Ansible, orchestrated by the Mars CLI. Supports Hyperledger Fabric blockchain networks, EKS clusters, and application Helm charts.

**Languages/tools:** HCL (Terraform >= 1.7.5), YAML (Ansible), Bash, Mars CLI (v0.92.0)

## Architecture

### Terraform Provisioning Stages (sequential)

Each stage lives in `tf/<stage>/` and is run via `tf/plan.sh` or `tf/apply.sh` from within that directory:

1. **account-provision** - AWS Organization account creation
2. **account-setup** - IAM role bootstrap
3. **cloud-provision** - Core networking, DNS, S3/GCS state bucket, KMS
4. **vm-provision** - EKS worker nodes, service-account IAM roles (reads cloud-provision state)
5. **k8s-provision** - EKS cluster config (namespaces, RBAC, aws-auth)
6. **custom-stack-provision** - Customer-specific overlay

Stages share data via `tf/auto-vars/*.json` (auto-loaded tfvars) and Terraform remote state data sources.

### Dual-Cloud Pattern

Cloud selection via `cloud_provider` variable (`"aws"` or `"gcp"`). Resources use conditional `count`:
```hcl
locals {
  is_aws = var.cloud_provider == "aws"
  is_gcp = var.cloud_provider == "gcp"
}
resource "aws_thing" "x" { count = local.is_aws ? 1 : 0 }
resource "google_thing" "x" { count = local.is_gcp ? 1 : 0 }
```

### Ansible

Playbooks in `ansible/playbooks/`. Key ones: `app.yaml`, `site.yaml`, `k8s-setup.yaml`, `dlt-provision.yaml`.
Variables in `ansible/vars/` and `ansible/inventories/default/group_vars/all/`.

### Shell Utilities

`shell_utils.sh` provides: cloud provider detection (`getCloudProvider`, `isAWS`, `isGCP`), GCP credential management (`setupCloudEnv`/`cleanupCloudEnv`), git helpers (`gitCommit`, `gitMergeOriginMain`, `gitPushInfra`), and tfvar access (`getTfVar`, `mustGetTfVar`).

`tf/utils.sh` provides: `tfInit`, `tfPlan`, `tfApply`, `tfDestroy` wrappers that use Mars CLI. Also handles workspace setup, auto-vars copying, and plugin caching.

## Commands

### Terraform

```bash
# Plan (from within a stage directory, e.g. tf/cloud-provision)
cd tf/cloud-provision && bash ../plan.sh

# Apply (plans + applies + git commits + pushes to infra remote)
cd tf/cloud-provision && bash ../apply.sh

# Destroy
cd tf/cloud-provision && bash ../destroy.sh

# Enable debug logging
TF_LOG=DEBUG bash ../plan.sh
```

### Ansible (via GitHub Actions or locally)

```bash
# run-ansible.sh <playbook> <environment> <check_mode> <verbosity>
bash run-ansible.sh ansible/app.yaml default false 0

# Check mode (dry run) with verbose output
bash run-ansible.sh ansible/app.yaml default true 2
```

### Testing

```bash
# Validate GCP inspector IAM bindings
./test-inspector-iam.sh <gcp_project_id> <short_project_id>
```

There is no general test suite. Validation happens through `terraform plan` (dry run), Ansible `--check` mode, and the inspector IAM test script.

## CI/CD

GitHub Actions workflow (`.github/workflows/deploy.yml`):
- Triggers on push to `main` when `version.yaml` changes, or manual dispatch
- Uses AWS OIDC authentication (no static credentials)
- Required repository variables: `AWS_ROLE_ARN`, `AWS_REGION`
- Runs `run-ansible.sh` with configurable playbook, environment, check mode, and verbosity

## Key Files

| File | Purpose |
|------|---------|
| `shell_utils.sh` | Cloud detection, credential management, git helpers |
| `tf/utils.sh` | Terraform wrapper functions (init/plan/apply/destroy) |
| `tf/run-with-creds.sh` | Mars CLI credential injection wrapper |
| `tf/auto-vars/common.auto.tfvars.json` | Shared Terraform variables across stages |
| `ansible/inventories/default/group_vars/all/env.yaml` | Core Ansible environment config |
| `ansible/inventories/default/group_vars/all/version.yaml` | Version tracking (triggers CI deploys) |
| `.mars-version` | Pinned Mars CLI version |
| `mars` | Mars CLI executable wrapper |

## Conventions

- Terraform modules sourced from `github.com/luthersystems/tf-modules.git` with pinned `?ref=vX.Y.Z` tags
- Sensitive variables marked with `sensitive = true` in Terraform
- Git identity: `Luther DevBot <devbot@luthersystems.com>` for automated commits
- `secrets/` directory is gitignored; deploy keys go in `secrets/infra_deploy_key.pem`
- Two git remotes: `origin` (template repo) and `infra` (customer infrastructure repo, configured via `repo_clone_ssh_url` tfvar)
