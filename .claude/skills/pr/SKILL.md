# /pr -- Create a Pull Request

## Trigger

User asks to create a PR, open a pull request, or ship changes for review.

## Workflow

1. **Run verification** -- chain to `/verify` to ensure everything is clean.

2. **Check branch state:**
   ```bash
   git branch --show-current
   git status
   git log --oneline main..HEAD
   ```
   - Must NOT be on `main` -- if so, create a feature branch first
   - All changes must be committed

3. **Push to remote:**
   ```bash
   git push -u origin <branch-name>
   ```

4. **Create the PR:**
   ```bash
   gh pr create --title "<concise title>" --body "$(cat <<'EOF'
   ## Summary
   <1-3 bullet points describing what changed and why>

   ## Test plan
   - [ ] <verification steps>

   🤖 Generated with [Claude Code](https://claude.com/claude-code)
   EOF
   )"
   ```

5. **Wait for CI checks:**
   ```bash
   gh pr checks
   ```
   If checks fail, fix the failures and push again.

6. **Report the PR URL** to the user.

## PR Title Guidelines

- Under 70 characters
- Imperative mood: "Add X", "Fix Y", "Update Z"
- No issue numbers in title (put them in the body)

## Anti-patterns

- Do not push directly to `main`
- Do not create a PR with uncommitted changes
- Do not skip verification before creating a PR
- Do not force-push without explicit user approval

## Checklist

- [ ] Verification passed (`/verify`)
- [ ] On a feature branch, not `main`
- [ ] All changes committed
- [ ] PR title is concise and descriptive
- [ ] PR body has summary and test plan
- [ ] CI checks pass
