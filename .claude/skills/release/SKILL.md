# /release -- Create a Release

## Trigger

User asks to release, deploy, bump the version, or trigger a deployment.

## Workflow

1. **Understand the release mechanism:**
   - CI deploys are triggered by changes to `ansible/inventories/default/group_vars/all/version.yaml` on `main`
   - The `version.yaml` file contains version references used by Ansible playbooks
   - Pushing a change to this file on `main` triggers the GitHub Actions deploy workflow

2. **Determine what to bump.** Key version fields in `version.yaml`:
   - `phylum_version` (set via `app_version`)
   - `substrate_chaincode_version` (set via `substrate_version`)
   - Related client/gateway versions

   The actual version values come from `env.yaml` variables (`app_version`, `substrate_version`). Check both files:
   ```bash
   cat ansible/inventories/default/group_vars/all/version.yaml
   cat ansible/inventories/default/group_vars/all/env.yaml
   ```

3. **Create the version change:**
   - Create a feature branch if not already on one
   - Update the version values in `env.yaml` or `version.yaml` as appropriate
   - Chain to `/verify` to validate

4. **Create a PR** -- chain to `/pr`:
   - Title: "Release: bump <component> to <version>"
   - The PR body should clearly state what version is being deployed

5. **After the PR is merged to `main`**, the CI pipeline will:
   - Detect the `version.yaml` change
   - Run `run-ansible.sh` with `app.yaml`
   - Deploy to the configured environment

6. **Monitor the deployment:**
   ```bash
   gh run list --workflow=deploy.yml --limit 5
   gh run watch <run-id>
   ```

## Anti-patterns

- Do not push version changes directly to `main` -- always use a PR
- Do not bump versions without understanding what will be deployed
- Do not skip monitoring the deployment after merge
- Do not modify `version.yaml` for non-deployment purposes (it triggers CI)

## Checklist

- [ ] Current versions reviewed
- [ ] Version bump identified and applied
- [ ] Changes verified (`/verify`)
- [ ] PR created with clear release description (`/pr`)
- [ ] Deployment monitored after merge
