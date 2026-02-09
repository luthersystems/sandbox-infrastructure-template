# /implement -- Implement a Code Change

## Trigger

User asks to make a change to Terraform, Ansible, Bash scripts, or documentation in this repo.

## Workflow

1. **Classify the change type:**
   - Terraform resource → chain to `/add-terraform-resource` or `/add-cloud-resource`
   - New integration test → chain to `/add-test`
   - Ansible playbook/vars → follow Ansible conventions below
   - Shell script → follow Shell conventions below
   - Documentation → edit in-place

2. **Create a feature branch** (if not already on one):
   ```bash
   git checkout -b <type>/<short-description>
   ```
   Branch prefixes: `feature/`, `fix/`, `refactor/`

3. **Read before writing** -- always read the file you're modifying first. Understand existing patterns.

4. **Make the change**, following the conventions for the file type:

   **Terraform (.tf)**
   - Use the dual-cloud conditional count pattern when adding resources (see `/add-cloud-resource`)
   - Source modules from `github.com/luthersystems/tf-modules.git` with pinned `?ref=vX.Y.Z`
   - Mark sensitive variables with `sensitive = true`
   - Place resources in the appropriate stage directory under `tf/<stage>/`

   **Ansible (.yaml)**
   - Playbooks go in `ansible/` (top-level)
   - Variables go in `ansible/vars/` or `ansible/inventories/default/group_vars/all/`
   - Follow existing playbook structure (hosts, roles, tasks)

   **Shell scripts (.sh)**
   - Use `set -euo pipefail` at the top
   - Source `shell_utils.sh` for cloud detection and git helpers when needed
   - Use functions from `tf/utils.sh` for Terraform operations

   **Documentation**
   - Update `CLAUDE.md` if adding new commands, conventions, or key files
   - Keep `README.md` in sync if user-facing behavior changes

5. **Run verification** -- chain to `/verify` to validate the change.

6. **Commit with a descriptive message** following the repo's style:
   ```bash
   git add <specific-files>
   git commit -m "<descriptive message>"
   ```

## Anti-patterns

- Do not modify files you haven't read first
- Do not add resources to the wrong Terraform stage
- Do not hardcode cloud-specific values without the dual-cloud conditional pattern
- Do not create new shell scripts without `set -euo pipefail`
- Do not commit secrets, credentials, or files in `secrets/`

## Checklist

- [ ] Read existing file before modifying
- [ ] Change follows conventions for the file type
- [ ] No secrets or sensitive values committed
- [ ] Verification passed (`/verify`)
- [ ] Commit message is descriptive
