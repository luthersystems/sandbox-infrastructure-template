# sandbox-infrastructure-template

Luther Systems "Mars" infrastructure template. This repo is the **base template** that [Oracle](https://github.com/luthersystems/ui-core) (the deployment service) clones as the starting point for every customer infrastructure deployment.

## How it fits in the deployment pipeline

1. **[InsideOut](https://github.com/luthersystems/reliable)** composes Terraform files from session data and sends them as inline archives to Oracle via `POST /v1/ui/networks/custom-stack`.
2. **[Oracle](https://github.com/luthersystems/ui-core)** orchestrates Argo workflows that clone this template repo.
3. Oracle runs `prepare-custom-stack.sh` to inject customer TF files into the `tf/custom-stack-provision/` directory, then runs Terraform.

## Key scripts

| Script | Purpose |
|--------|---------|
| `prepare-custom-stack.sh` | Injects customer TF files into `tf/custom-stack-provision/`. Supports inline base64-encoded tar archives (preferred) or cloning a custom git repo (fallback). |
| `shell_utils.sh` | Shared helpers: `getTfVar`, `mustGetTfVar`, cloud provider detection, credential management, git helpers. |
| `tf/utils.sh` | Terraform wrapper functions (`tfInit`, `tfPlan`, `tfApply`, `tfDestroy`) using Mars CLI. |
| `run-ansible.sh` | Ansible playbook runner with configurable environment, check mode, and verbosity. |

## Directory structure

```
tf/
  cloud-provision/          # Bootstrap: IAM roles, S3/GCS buckets, Route53/DNS, GitHub repos
  vm-provision/             # VM layer: EKS worker nodes, service-account IAM roles, storage
  k8s-provision/            # Kubernetes layer: namespaces, RBAC, aws-auth
  custom-stack-provision/   # Customer TF: injected by prepare-custom-stack.sh
ansible/
  playbooks/                # Ansible playbooks (app, site, k8s-setup, dlt-provision)
  inventories/              # Environment configs and variables
tests/                      # Integration tests
```

## Terraform provisioning stages (sequential)

1. **account-provision** — AWS Organization account creation
2. **account-setup** — IAM role bootstrap
3. **cloud-provision** — Core networking, DNS, S3/GCS state bucket, KMS
4. **vm-provision** — EKS worker nodes, service-account IAM roles
5. **k8s-provision** — EKS cluster config (namespaces, RBAC, aws-auth)
6. **custom-stack-provision** — Customer-specific overlay

Stages share data via `tf/auto-vars/*.json` and Terraform remote state data sources.

## Dual-cloud support

Cloud selection via `cloud_provider` variable (`"aws"` or `"gcp"`). Resources use conditional `count` to instantiate only the relevant provider's resources.

## Related repos

| Repo | Role |
|------|------|
| [luthersystems/ui-core](https://github.com/luthersystems/ui-core) | Oracle deployment service; orchestrates Argo workflows and calls this template |
| [luthersystems/reliable](https://github.com/luthersystems/reliable) | InsideOut web app + Go backend; composes TF files from session data |
| [luthersystems/tf-modules](https://github.com/luthersystems/tf-modules) | Shared Terraform modules referenced by the bootstrap step |

## Running tests

```bash
bash tests/test-prepare-custom-stack.sh
```

## CI/CD

GitHub Actions workflow (`.github/workflows/deploy.yml`):
- Triggers on push to `main` when `version.yaml` changes, or manual dispatch
- Uses AWS OIDC authentication (no static credentials)
- Required repository variables: `AWS_ROLE_ARN`, `AWS_REGION`

---

> This template is intended to serve as the canonical starting point for any new sandbox project using the Luther "Mars" infrastructure pipeline.
