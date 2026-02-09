# /pickup-issue -- Pick Up and Complete a GitHub Issue

## Trigger

User asks to work on a GitHub issue, pick up an issue, or references an issue number.

## Workflow

1. **Read the issue:**
   ```bash
   gh issue view <number>
   ```
   Understand the requirements, acceptance criteria, and any linked issues.

2. **Create a feature branch:**
   ```bash
   git checkout main
   git pull origin main
   git checkout -b <type>/<short-description>
   ```
   Use the issue title/content to derive the branch name.

3. **Plan the implementation:**
   - Enter plan mode for non-trivial changes
   - Identify which files need to change
   - Determine the appropriate skill to chain to

4. **Implement the change** -- chain to the appropriate skill:
   - General code change → `/implement`
   - New Terraform resource → `/add-terraform-resource` or `/add-cloud-resource`
   - New test → `/add-test`
   - Version bump / release → `/release`

5. **Verify** -- chain to `/verify`.

6. **Create a PR** -- chain to `/pr`. Reference the issue in the PR body:
   ```
   Closes #<number>
   ```

7. **Comment on the issue** (optional, if useful):
   ```bash
   gh issue comment <number> --body "PR created: <pr-url>"
   ```

## Anti-patterns

- Do not start coding without reading the issue first
- Do not work on `main` directly
- Do not create a PR without referencing the issue
- Do not close the issue manually (let the PR close it via "Closes #N")

## Checklist

- [ ] Issue requirements understood
- [ ] Feature branch created from latest `main`
- [ ] Implementation complete
- [ ] Verification passed (`/verify`)
- [ ] PR created with `Closes #<number>` in body
