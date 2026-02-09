# /verify -- Verify Changes Before Shipping

## Trigger

User asks to validate, check, or verify changes. Also called automatically by `/pr` and `/implement`.

## Workflow

1. **Check git status** for unexpected files:
   ```bash
   git status
   ```
   Ensure no secrets, `.env` files, or `secrets/` directory contents are staged.

2. **Validate shell scripts** (if any .sh files were changed):
   ```bash
   # Syntax check
   bash -n <script.sh>

   # Lint (if shellcheck is available)
   shellcheck <script.sh>
   ```

3. **Validate Terraform** (if any .tf files were changed):
   ```bash
   # From within the stage directory
   cd tf/<stage> && terraform validate
   ```
   Note: `terraform validate` requires `terraform init` to have been run. If init hasn't been run, skip this step and note it.

4. **Validate JSON** (if any .json files were changed):
   ```bash
   python3 -c "import json; json.load(open('<file>.json'))"
   ```
   Key files to check: `tf/auto-vars/common.auto.tfvars.json`, `.claude/settings.json`

5. **Validate YAML** (if any .yaml files were changed):
   ```bash
   python3 -c "import yaml; yaml.safe_load(open('<file>.yaml'))" 2>/dev/null || echo "YAML validation requires PyYAML"
   ```

6. **Run integration tests** (if test files exist for the changed area):
   ```bash
   # Custom stack tests
   bash tests/test-prepare-custom-stack.sh
   ```

7. **Check for common issues:**
   - Terraform modules reference pinned versions (`?ref=vX.Y.Z`)
   - No hardcoded AWS account IDs or GCP project IDs
   - Sensitive variables marked with `sensitive = true`
   - Shell scripts have `set -euo pipefail`

8. **Report results** -- summarize what passed, what failed, and what was skipped.

## Anti-patterns

- Do not skip verification because "it's a small change"
- Do not ignore shellcheck warnings without understanding them
- Do not run `terraform apply` as part of verification (use `terraform validate` or `terraform plan` only)

## Checklist

- [ ] `git status` shows only expected changes
- [ ] Shell scripts pass `bash -n` syntax check
- [ ] Terraform files pass `terraform validate` (if init'd)
- [ ] JSON files are valid
- [ ] No secrets or credentials in staged files
- [ ] Integration tests pass (if applicable)
