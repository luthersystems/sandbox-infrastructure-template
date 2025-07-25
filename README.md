# sandbox-infrastructure-template

A GitHub Template repository for Luther’s “Mars” infrastructure projects. It bundles all of the Terraform and Ansible code you need to stand up a complete sandbox environment in AWS, including:

- **account-provision** & **account-setup** – create a new AWS Organization account and initial IAM roles
- **cloud-provision** – bootstrap the core networking, DNS, S3 buckets, and Terraform state
- **vm-provision** – spin up EKS worker nodes, service‐account IAM roles, and storage
- **k8s-provision** – configure your EKS cluster (namespaces, aws-auth, RBAC)
- **dlt-provision** – deploy a Hyperledger Fabric network via Ansible
- **license** & **certs** – generate application licenses and crypto artifacts
- **umbrella** – install your application’s Helm charts (shiroclient, connectorhub, oracle, ingress)

---

_IMPORTANT_: This repo is mainly for internal use. We've made it public to make
deployments easier and provide visibility.

---

## 📁 Repository Structure

```
├── ansible/               # playbooks & inventories (fabric, k8s, umbrella, etc.)
├── fabric/                # fabric-network-builder wrappers (fnb-gen.sh)
├── license/               # license-gen.sh
└── tf/                    # terraform modules & workflows
    ├── account-provision/
    ├── account-setup/
    ├── cloud-provision/
    ├── vm-provision/
    └── k8s-provision/
```

---

## 🔧 Prerequisites

- **Terraform** ≥ 1.7.5
- **Ansible**
- **AWS CLI** & credentials / roles for:

  - Org-creator (create new AWS accounts)
  - Terraform service account
  - Ansible service account

- **Argo Workflows** (via the `mars` CLI)

---

## 📝 Customization

- **Defaults & Roles**
  Edit `ansible/vars/umbrella.yaml` or `ansible/vars/common.yaml` to point at your cert ARNs, domains, and service-account IAM roles.

- **Terraform Modules**
  Reference your own module versions by updating the `source = "github.com/luthersystems/tf-modules?ref=…”` lines.

- **Bootstrap Settings**
  Override any of the baked-in defaults for account naming, OU placement, or billing access via TF variables in `tf/auto-vars/…`.

---

> This template is intended to serve as the canonical starting point for any new sandbox project using the Luther “Mars” infrastructure pipeline. Happy provisioning!
