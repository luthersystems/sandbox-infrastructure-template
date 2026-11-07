locals {
  repo_name = "${var.short_project_id}-infra"

  # The org of the repo an earlier run created, from the clone URL it
  # recorded in git_repo.auto.tfvars.json ("" before the first run).
  recorded_repo_org = lower(try(regex("^git@github\\.com:([^/]+)/", var.repo_clone_ssh_url)[0], ""))
}

# The org the repo was first created in. It keeps that value when repo_org
# changes later (ignore_changes), so the precondition below can tell a
# project's org apart from the one this run was given. A project that already
# has a repo but no pin (created before this resource) takes the org from its
# recorded clone URL, so the run that adds the pin is guarded too.
# common-infrastructure#269.
#
# A move to another org (ui-core's move-infra-repo command,
# ui-infrastructure#442) transfers the repo and records the new org and clone
# URL in git_repo.auto.tfvars.json. triggers_replace follows the recorded
# clone URL's org, so that change replaces the pin, and the new pin takes the
# new org. A repo_org change alone (no transfer) leaves the record, so the
# pin keeps the old org and the precondition below still fails the run. The
# first run with this trigger replaces each existing pin once, with the same
# org; on that run the precondition is checked at apply, not at plan.
resource "terraform_data" "repo_org_pin" {
  input            = local.recorded_repo_org != "" ? local.recorded_repo_org : lower(var.repo_org)
  triggers_replace = local.recorded_repo_org != "" ? local.recorded_repo_org : null

  lifecycle {
    ignore_changes = [input]
  }
}

# With ui-core's GitHub App (ui-infrastructure#442), ui-core creates the
# repo with the App before Terraform runs, so the repo joins the App's
# installation and the step's token, limited to this one repo, can reach it.
# That token cannot create a repo, so Terraform adopts the repo here instead.
# An import of a resource already in state is a no-op, so this is safe on
# every run. Off (the default) keeps the org PAT flow, where Terraform
# creates the repo and an import would fail on a repo that does not exist.
import {
  for_each = var.adopt_infra_repo ? toset([local.repo_name]) : toset([])
  to       = github_repository.infra
  id       = each.value
}

# GitHub repo is created for both AWS and GCP
resource "github_repository" "infra" {
  name        = local.repo_name
  description = "Infrastructure repo for ${var.short_project_id}"
  visibility  = "private"

  // optional settings:
  has_issues           = true
  has_wiki             = false
  vulnerability_alerts = var.vulnerability_alerts

  lifecycle {
    # With another repo_org, the provider looks the repo up in the new org,
    # does not find it, and plans a new, empty repo there: the stack's
    # history stays behind and the customer AWS account's OIDC trust is
    # rewritten to the new repo. Fail instead. Usually an existing project
    # already keeps its org: git_repo.auto.tfvars.json (below) records it and
    # loads after common.auto.tfvars.json, where Oracle's repo_org lands. This
    # catches the case where that file has no repo_org. GitHub org names are
    # case-insensitive, so the check is too. To move a project, run ui-core's
    # move-infra-repo command, or by hand: transfer its repo on GitHub, then
    # set repo_org and repo_clone_ssh_url in the project's
    # tf/auto-vars/git_repo.auto.tfvars.json (the pin follows; see
    # repo_org_pin).
    precondition {
      condition     = terraform_data.repo_org_pin.output == lower(var.repo_org)
      error_message = "repo_org changed from \"${terraform_data.repo_org_pin.output}\" to \"${var.repo_org}\" for an existing project. A project's -infra repo stays in the org it was created in (common-infrastructure#269). To move it, use ui-core's jobs move-infra-repo (ui-infrastructure#442)."
    }
  }
}

# A write deploy key, for git over SSH to the repo (shell_utils.sh). Off with
# ui-core's GitHub App (TF_VAR_create_infra_deploy_key=false): the repo is
# then in an org where deploy keys are off, and git uses the step's App token
# over HTTPS instead. Turning it off destroys the key and its file.
resource "tls_private_key" "deploy" {
  count     = var.create_infra_deploy_key ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "github_repository_deploy_key" "infra" {
  count      = var.create_infra_deploy_key ? 1 : 0
  repository = github_repository.infra.name
  title      = "infra-deploy-key"
  key        = tls_private_key.deploy[0].public_key_openssh
  read_only  = false
}

# Persist private key to local file
resource "local_file" "deploy_private_key" {
  count           = var.create_infra_deploy_key ? 1 : 0
  content         = tls_private_key.deploy[0].private_key_pem
  filename        = "${path.module}/../../secrets/infra_deploy_key.pem"
  file_permission = "0400"
}

output "repo_clone_ssh_url" {
  description = "The SSH clone URL of the new repo"
  value       = github_repository.infra.ssh_clone_url
}

resource "local_file" "git_repo_tfvars" {
  filename = "${path.module}/../auto-vars/git_repo.auto.tfvars.json"

  content = jsonencode({
    repo_clone_ssh_url = github_repository.infra.ssh_clone_url
    repo_name          = github_repository.infra.name
    repo_org           = var.repo_org
  })
}

# Wait for repository to be fully ready before creating Actions variables
# This prevents race conditions where the GitHub API hasn't propagated
# the repository yet, causing "inconsistent result" errors.
resource "time_sleep" "wait_for_repo_ready" {
  depends_on = [github_repository.infra]

  create_duration = "10s"
}

# AWS-specific: Set AWS_REGION variable in GitHub Actions
resource "github_actions_variable" "aws_region" {
  count = local.is_aws ? 1 : 0

  depends_on = [time_sleep.wait_for_repo_ready]

  repository    = github_repository.infra.name
  variable_name = "AWS_REGION"
  value         = var.aws_region != "" ? var.aws_region : "us-west-2"
}

# GCP-specific: Set GCP variables in GitHub Actions
resource "github_actions_variable" "gcp_project" {
  count = local.is_gcp ? 1 : 0

  depends_on = [time_sleep.wait_for_repo_ready]

  repository    = github_repository.infra.name
  variable_name = "GCP_PROJECT"
  value         = var.gcp_project_id
}

resource "github_actions_variable" "gcp_region" {
  count = local.is_gcp ? 1 : 0

  depends_on = [time_sleep.wait_for_repo_ready]

  repository    = github_repository.infra.name
  variable_name = "GCP_REGION"
  value         = var.gcp_region
}

# Invite the deploying user as a collaborator on the new repo
resource "github_repository_collaborator" "user" {
  count = var.github_username != "" ? 1 : 0

  depends_on = [time_sleep.wait_for_repo_ready]

  repository = github_repository.infra.name
  username   = var.github_username
  permission = var.collaborator_permission
}

# The deploy key resources took a count (create_infra_deploy_key). Keep an
# existing project's key, not a new one.
moved {
  from = tls_private_key.deploy
  to   = tls_private_key.deploy[0]
}

moved {
  from = github_repository_deploy_key.infra
  to   = github_repository_deploy_key.infra[0]
}

moved {
  from = local_file.deploy_private_key
  to   = local_file.deploy_private_key[0]
}
