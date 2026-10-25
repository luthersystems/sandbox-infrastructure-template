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
# The test copies the real repo.tf into a scratch module with mock providers
# and runs `terraform test`:
#   1. a first apply creates the repo and pins its org;
#   2. a later plan with the same org passes;
#   3. a later plan with another org fails the precondition;
#   4. -replace of the pin (the documented move path) accepts the new org.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="${TERRAFORM:-terraform}"

if ! command -v "$TF" >/dev/null 2>&1; then
  echo "FAIL: terraform not found (set TERRAFORM)" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp "$ROOT/tf/cloud-provision/repo.tf" "$work/repo.tf"

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

provider "github" {
  owner = var.repo_org
}

locals {
  is_aws = true
  is_gcp = false
}

variable "short_project_id" {
  type    = string
  default = "abcd1234"
}

variable "repo_org" {
  type    = string
  default = "luthersystems"
}

variable "github_username" {
  type    = string
  default = ""
}

variable "collaborator_permission" {
  type    = string
  default = "admin"
}

variable "vulnerability_alerts" {
  type    = bool
  default = true
}

variable "aws_region" {
  type    = string
  default = "us-west-2"
}

variable "gcp_project_id" {
  type    = string
  default = ""
}

variable "gcp_region" {
  type    = string
  default = ""
}
EOF

mkdir -p "$work/tests"
cat >"$work/tests/pin.tftest.hcl" <<'EOF'
mock_provider "github" {}
mock_provider "local" {}
mock_provider "time" {}
mock_provider "tls" {}

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

run "other_org_fails" {
  command = plan

  variables {
    repo_org = "insideout-envs"
  }

  expect_failures = [github_repository.infra]
}

run "replace_pin_moves_org" {
  command = plan

  plan_options {
    replace = [terraform_data.repo_org_pin]
  }

  variables {
    repo_org = "insideout-envs"
  }
}
EOF

cd "$work"
"$TF" init -backend=false -input=false >/dev/null
if "$TF" test; then
  echo "PASS: repo_org pin"
else
  echo "FAIL: repo_org pin" >&2
  exit 1
fi
