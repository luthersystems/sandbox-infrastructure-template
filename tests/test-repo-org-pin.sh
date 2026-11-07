#!/usr/bin/env bash
set -euo pipefail

# Guards the repo_org pin in tf/cloud-provision/repo.tf
# (common-infrastructure#269).
#
# repo_org names the GitHub org a project's -infra repo lives in. ui-core
# sends it on every run. If a later run sends another org, the github
# provider looks the repo up in the new org, does not find it, and plans a
# new, empty repo there. The pin keeps the org the repo was created in, and
# a precondition on github_repository.infra fails such a plan.
#
# The test copies the real stage files into a scratch module with mock
# providers and runs `terraform test`:
#   1. a first apply creates the repo and pins its org;
#   2. a later plan with the same org passes;
#   3. the org check ignores case, as GitHub does;
#   4. a later plan with another org fails the precondition;
#   5. -replace of the pin (the documented move path) records the new org;
#   6. a project whose repo predates the pin seeds it from the recorded clone
#      URL, so the run that adds the pin is guarded too;
#   7. with adopt_infra_repo, the import block is valid and the runs plan
#      and apply; its shape (target, id, condition) is checked by pattern;
#   8. infra_repo_moved_to_org (ui-core's move-infra-repo, #442) re-pins a
#      moved project to its new org, keeps it on later runs, and fails when
#      it differs from repo_org.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="${TERRAFORM:-terraform}"

if ! command -v "$TF" >/dev/null 2>&1; then
  echo "FAIL: terraform not found (set TERRAFORM)" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The real stage files, so the test follows their variables and provider.
# main.tf (which defines is_aws/is_gcp among much else) and the per-cloud
# templates are left out; stub.tf supplies what repo.tf needs from them.
for f in repo.tf vars.tf unused-vars.tf providers.tf versions.tf; do
  cp "$ROOT/tf/cloud-provision/$f" "$work/$f"
done

cat >"$work/stub.tf" <<'EOF'
terraform {
  required_providers {
    github = {
      source = "integrations/github"
    }
    local = {
      source = "hashicorp/local"
    }
    time = {
      source = "hashicorp/time"
    }
    tls = {
      source = "hashicorp/tls"
    }
  }
}

locals {
  is_aws = true
  is_gcp = false
}
EOF

mkdir -p "$work/tests"
cat >"$work/tests/pin.tftest.hcl" <<'EOF'
mock_provider "github" {}
mock_provider "local" {}
mock_provider "time" {}
mock_provider "tls" {}

variables {
  domain           = "example.com"
  short_project_id = "abcd1234"
  project_id       = "abcd1234-project"
}

run "create_pins_org" {
  command = apply

  variables {
    repo_org = "luthersystems"
  }

  assert {
    condition     = terraform_data.repo_org_pin.output == "luthersystems"
    error_message = "the first apply did not pin repo_org"
  }
}

run "same_org_passes" {
  command = plan

  variables {
    repo_org = "luthersystems"
  }
}

run "same_org_other_case_passes" {
  command = plan

  variables {
    repo_org = "LutherSystems"
  }
}

run "other_org_fails" {
  command = plan

  variables {
    repo_org = "insideout-envs"
  }

  expect_failures = [github_repository.infra]
}

run "replace_pin_moves_org" {
  command = apply

  plan_options {
    replace = [terraform_data.repo_org_pin]
  }

  variables {
    repo_org = "insideout-envs"
  }

  assert {
    condition     = terraform_data.repo_org_pin.output == "insideout-envs"
    error_message = "replacing the pin did not record the new org"
  }
}
EOF

# A project whose repo predates the pin: its state has no pin, and its
# git_repo.auto.tfvars.json recorded the clone URL but no repo_org. A new
# pin's output is unknown until apply, so the precondition runs at apply:
# these runs apply.
cat >"$work/tests/seed.tftest.hcl" <<'EOF'
mock_provider "github" {}
mock_provider "local" {}
mock_provider "time" {}
mock_provider "tls" {}

variables {
  domain             = "example.com"
  short_project_id   = "abcd1234"
  project_id         = "abcd1234-project"
  repo_clone_ssh_url = "git@github.com:luthersystems/abcd1234-infra.git"
}

run "unpinned_project_other_org_fails" {
  command = apply

  variables {
    repo_org = "insideout-envs"
  }

  expect_failures = [github_repository.infra]
}

run "unpinned_project_same_org_passes" {
  command = apply

  variables {
    repo_org = "luthersystems"
  }

  assert {
    condition     = terraform_data.repo_org_pin.output == "luthersystems"
    error_message = "the pin did not take the org from the recorded clone URL"
  }
}
EOF

# ui-core's GitHub App (ui-infrastructure#442) creates the repo before this
# stage runs, and the stage adopts it with an import block. A mock provider
# cannot import, so these runs prove only that the import block is valid
# config and that runs with the flag on plan and apply; the shape of the
# block itself is checked with a pattern after the test.
cat >"$work/tests/adopt.tftest.hcl" <<'EOF'
mock_provider "github" {}
mock_provider "local" {}
mock_provider "time" {}
mock_provider "tls" {}

# A mock provider cannot import; override_resource gives the imported repo.
override_resource {
  target = github_repository.infra
  values = {
    name = "abcd1234-infra"
  }
}

variables {
  domain           = "example.com"
  short_project_id = "abcd1234"
  project_id       = "abcd1234-project"
  repo_org         = "luthersystems"
}

run "new_project_adopts_repo" {
  command = apply

  variables {
    adopt_infra_repo = true
  }

  assert {
    condition     = github_repository.infra.name == "abcd1234-infra"
    error_message = "the adopted repo is not the project's"
  }
}

run "adopted_repo_in_state_is_kept" {
  command = plan

  variables {
    adopt_infra_repo = true
  }

  assert {
    condition     = github_repository.infra.name == "abcd1234-infra"
    error_message = "a second run with the flag lost the repo"
  }
}
EOF

# ui-core's move-infra-repo (ui-infrastructure#442) transfers a project's
# repo to another org, records the new org and clone URL, and sets
# infra_repo_moved_to_org. The pin must follow without -replace.
cat >"$work/tests/move.tftest.hcl" <<'EOF2'
mock_provider "github" {}
mock_provider "local" {}
mock_provider "time" {}
mock_provider "tls" {}

variables {
  domain           = "example.com"
  short_project_id = "abcd1234"
  project_id       = "abcd1234-project"
}

run "create_in_old_org" {
  command = apply

  variables {
    repo_org           = "luthersystems"
    repo_clone_ssh_url = "git@github.com:luthersystems/abcd1234-infra.git"
  }

  assert {
    condition     = terraform_data.repo_org_pin.output == "luthersystems"
    error_message = "the first apply did not pin repo_org"
  }
}

run "not_moved_keeps_pin" {
  command = plan

  variables {
    repo_org           = "luthersystems"
    repo_clone_ssh_url = "git@github.com:luthersystems/abcd1234-infra.git"
  }

  assert {
    condition     = terraform_data.repo_org_pin.output == "luthersystems"
    error_message = "a run with no move changed the pin"
  }
}

run "moved_var_other_than_repo_org_fails" {
  command = plan

  variables {
    repo_org                = "luthersystems"
    repo_clone_ssh_url      = "git@github.com:luthersystems/abcd1234-infra.git"
    infra_repo_moved_to_org = "luthersystems-infra"
  }

  expect_failures = [terraform_data.repo_org_pin]
}

run "move_repins_to_new_org" {
  command = apply

  variables {
    repo_org                = "luthersystems-infra"
    repo_clone_ssh_url      = "git@github.com:luthersystems-infra/abcd1234-infra.git"
    infra_repo_moved_to_org = "Luthersystems-Infra"
  }

  assert {
    condition     = terraform_data.repo_org_pin.output == "luthersystems-infra"
    error_message = "the move did not re-pin the new org"
  }
}

run "moved_project_later_run_passes" {
  command = apply

  variables {
    repo_org                = "luthersystems-infra"
    repo_clone_ssh_url      = "git@github.com:luthersystems-infra/abcd1234-infra.git"
    infra_repo_moved_to_org = "luthersystems-infra"
  }

  assert {
    condition     = terraform_data.repo_org_pin.output == "luthersystems-infra"
    error_message = "a later run of a moved project lost the pin"
  }
}

run "moved_project_back_to_old_org_fails" {
  command = plan

  variables {
    repo_org                = "luthersystems"
    repo_clone_ssh_url      = "git@github.com:luthersystems-infra/abcd1234-infra.git"
    infra_repo_moved_to_org = "luthersystems-infra"
  }

  expect_failures = [terraform_data.repo_org_pin]
}
EOF2

cd "$work"
"$TF" init -backend=false -input=false >/dev/null
if "$TF" test; then
  echo "PASS: repo_org pin"
else
  echo "FAIL: repo_org pin" >&2
  exit 1
fi

# The import block must adopt github_repository.infra by the project's repo
# name, and only with adopt_infra_repo: an unconditional import fails a
# project on the PAT flow, whose repo Terraform creates.
block="$(awk '/^import \{/,/^\}/' "$ROOT/tf/cloud-provision/repo.tf" | tr -s ' ')"
for want in \
  'for_each = var.adopt_infra_repo ? toset([local.repo_name]) : toset([])' \
  'to = github_repository.infra' \
  'id = each.value'; do
  if ! grep -qF -- "$want" <<<"$block"; then
    echo "FAIL: the repo import block lacks: $want" >&2
    exit 1
  fi
done
echo "PASS: repo import block"
