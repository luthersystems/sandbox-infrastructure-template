# /terraform-plan -- Run Terraform Plan

## Trigger

User asks to plan, dry-run, or preview Terraform changes for a stage.

## Workflow

1. **Identify the stage.** Valid stages:
   - `account-provision`
   - `account-setup`
   - `cloud-provision`
   - `vm-provision`
   - `k8s-provision`
   - `custom-stack-provision`

   If the user doesn't specify a stage, ask which one.

2. **Run the plan:**
   ```bash
   cd tf/<stage> && bash ../plan.sh
   ```

   For verbose/debug output:
   ```bash
   cd tf/<stage> && TF_LOG=DEBUG bash ../plan.sh
   ```

3. **Review the output:**
   - Summarize resources to be added, changed, or destroyed
   - Flag any unexpected destroys or replacements
   - Note any errors or warnings

4. **Report results** to the user with a clear summary of planned changes.

## Prerequisites

- Mars CLI must be installed (check `.mars-version` for required version)
- Cloud credentials must be configured
- `tf/auto-vars/common.auto.tfvars.json` must exist with required variables

## Anti-patterns

- Do not run `terraform apply` when the user asked for a plan
- Do not ignore destroy actions in the plan output
- Do not skip reviewing the plan output before reporting

## Checklist

- [ ] Correct stage identified
- [ ] `plan.sh` executed from within the stage directory
- [ ] Plan output reviewed and summarized
- [ ] Any destroys or replacements flagged to the user
