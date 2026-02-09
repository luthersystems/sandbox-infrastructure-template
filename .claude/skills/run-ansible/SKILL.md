# /run-ansible -- Run an Ansible Playbook

## Trigger

User asks to run an Ansible playbook, deploy an application, or configure infrastructure.

## Workflow

1. **Identify the playbook.** Available playbooks in `ansible/`:

   | Playbook | Purpose |
   |----------|---------|
   | `app.yaml` | Deploy application |
   | `site.yaml` | Full site deployment |
   | `k8s-setup.yaml` | Kubernetes cluster setup |
   | `dlt-provision.yaml` | Distributed ledger provisioning |
   | `fabric_ca.yaml` | Fabric Certificate Authority |
   | `fabric_init.yaml` | Fabric network initialization |
   | `fabric_orderer.yaml` | Fabric orderer nodes |
   | `fabric_peer.yaml` | Fabric peer nodes |
   | `fabric_upgrade.yaml` | Fabric version upgrade |
   | `substrate_upgrade.yaml` | Substrate version upgrade |
   | `umbrella.yaml` | Umbrella Helm chart deployment |
   | `debug-shell.yaml` | Debug shell access |

2. **Choose execution method:**

   **Local execution:**
   ```bash
   bash run-ansible.sh ansible/<playbook> <environment> <check_mode> <verbosity>
   ```
   Parameters:
   - `<playbook>`: e.g., `app.yaml`
   - `<environment>`: e.g., `default`
   - `<check_mode>`: `true` (dry run) or `false` (apply)
   - `<verbosity>`: `0`-`3` (higher = more verbose)

   **CI dispatch (via GitHub Actions):**
   ```bash
   gh workflow run deploy.yml \
     -f playbook=<playbook> \
     -f environment=default \
     -f check_mode=false \
     -f verbosity=0
   ```

3. **For dry runs**, always run with check mode first:
   ```bash
   bash run-ansible.sh ansible/<playbook> default true 1
   ```

4. **Monitor CI execution** (if dispatched via GitHub Actions):
   ```bash
   gh run list --workflow=deploy.yml --limit 5
   gh run watch <run-id>
   ```

5. **Review output** for errors, changed tasks, and skipped tasks.

## Key Variable Files

- `ansible/inventories/default/group_vars/all/env.yaml` -- environment config
- `ansible/inventories/default/group_vars/all/version.yaml` -- version tracking (triggers CI on push)
- `ansible/vars/common.yaml` -- shared variables
- `ansible/vars/umbrella.yaml` -- Helm chart values

## Anti-patterns

- Do not run playbooks in apply mode without user confirmation
- Do not modify `version.yaml` without understanding it triggers CI deployment
- Do not run destructive playbooks (upgrades) without a dry run first
- Do not skip specifying the environment parameter

## Checklist

- [ ] Correct playbook identified
- [ ] Execution method chosen (local vs CI)
- [ ] Dry run completed first (for destructive operations)
- [ ] User confirmed before applying
- [ ] Output reviewed for errors
