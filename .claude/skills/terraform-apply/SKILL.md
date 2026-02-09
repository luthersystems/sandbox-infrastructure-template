# /terraform-apply -- Apply Terraform Changes

## Trigger

User asks to apply Terraform changes for a stage.

## Workflow

1. **Identify the stage.** Valid stages:
   - `account-provision`
   - `account-setup`
   - `cloud-provision`
   - `vm-provision`
   - `k8s-provision`
   - `custom-stack-provision`

   If the user doesn't specify a stage, ask which one.

2. **Confirm with the user** -- applying makes real infrastructure changes. Summarize what will happen.

3. **Run the apply:**
   ```bash
   cd tf/<stage> && bash ../apply.sh
   ```

   `apply.sh` does the following automatically:
   - Runs `terraform plan`
   - Runs `terraform apply`
   - Commits the state changes
   - Pushes to the `infra` remote

4. **Review the output:**
   - Confirm resources were created/modified/destroyed as expected
   - Note any errors
   - Verify the git commit and push succeeded

5. **Report results** to the user.

## Prerequisites

- Mars CLI must be installed (check `.mars-version`)
- Cloud credentials must be configured
- `tf/auto-vars/common.auto.tfvars.json` must exist
- The `infra` git remote must be configured (for auto-push)

## Anti-patterns

- Do not apply without user confirmation
- Do not apply without reviewing the plan first
- Do not ignore apply errors -- they may leave state in a partial state
- Do not manually run `terraform apply` -- always use `apply.sh` to get the git commit/push

## Checklist

- [ ] Correct stage identified
- [ ] User confirmed the apply
- [ ] `apply.sh` executed from within the stage directory
- [ ] Output reviewed for errors
- [ ] Git commit and push to `infra` remote succeeded
