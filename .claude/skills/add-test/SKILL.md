# /add-test -- Add an Integration Test

## Trigger

User asks to add a test, write a test, or increase test coverage.

## Workflow

1. **Identify what to test.** Common test targets:
   - Shell scripts (syntax, behavior)
   - Terraform configurations (validate, plan)
   - Custom stack preparation logic
   - GCP inspector IAM bindings

2. **Follow the existing test pattern** from `tests/test-prepare-custom-stack.sh`:

   ```bash
   #!/usr/bin/env bash
   set -euo pipefail

   PASS=0
   FAIL=0

   pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
   fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

   cleanup() { rm -rf "$WORKDIR"; }
   trap cleanup EXIT

   WORKDIR="$(mktemp -d)"

   # --- Setup ---
   # Create temporary directory structure mimicking the project

   # --- Execute ---
   # Run the script/operation being tested

   # --- Assertions ---
   if [[ <condition> ]]; then
     pass "<description>"
   else
     fail "<description>"
   fi

   # --- Summary ---
   echo ""
   echo "================================"
   echo "  $PASS passed, $FAIL failed"
   echo "================================"
   [[ $FAIL -eq 0 ]] && exit 0 || exit 1
   ```

3. **Key conventions from the pattern:**
   - Tests live in `tests/` directory
   - Named `test-<what-is-tested>.sh`
   - Use `pass()`/`fail()` helper functions for assertions
   - Use `trap cleanup EXIT` for temporary file cleanup
   - Use `mktemp -d` for isolated working directories
   - Handle macOS/Linux compatibility (see tar wrapper in existing test)
   - Exit 0 on all pass, exit 1 on any failure

4. **Write the test** following these conventions.

5. **Run the test:**
   ```bash
   bash tests/test-<name>.sh
   ```

6. **Verify the test passes.** If testing a bug fix, verify the test fails before the fix and passes after.

## Anti-patterns

- Do not write tests that depend on cloud credentials or external services
- Do not skip the cleanup trap (tests must not leave temp files)
- Do not write tests that only pass on a specific OS without compat wrappers
- Do not test implementation details -- test behavior and outcomes

## Checklist

- [ ] Test file created in `tests/` directory
- [ ] Follows `test-prepare-custom-stack.sh` pattern
- [ ] Uses `set -euo pipefail`
- [ ] Has cleanup trap
- [ ] Uses `pass()`/`fail()` assertion helpers
- [ ] Reports summary with pass/fail counts
- [ ] Test passes locally
