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
resource "terraform_data" "repo_org_pin" {
  input = local.recorded_repo_org != "" ? local.recorded_repo_org : lower(var.repo_org)

  lifecycle {
    ignore_changes = [input]
  }
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
    # case-insensitive, so the check is too. To move a project (by hand, with
    # Terraform against the project's state): transfer its repo on GitHub, set
    # repo_org and repo_clone_ssh_url in the project's
    # tf/auto-vars/git_repo.auto.tfvars.json, and apply with
    # `-replace=terraform_data.repo_org_pin`.
    precondition {
      condition     = terraform_data.repo_org_pin.output == lower(var.repo_org)
      error_message = "repo_org changed from \"${terraform_data.repo_org_pin.output}\" to \"${var.repo_org}\" for an existing project. A project's -infra repo stays in the org it was created in (common-infrastructure#269)."
    }
  }
}

# Generate an SSH keypair for deploy
resource "tls_private_key" "deploy" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Add the public key as a writeable deploy key on the repo
resource "github_repository_deploy_key" "infra" {
  repository = github_repository.infra.name
  title      = "infra-deploy-key"
  key        = tls_private_key.deploy.public_key_openssh
  read_only  = false
}

# Persist private key to local file
resource "local_file" "deploy_private_key" {
  content         = tls_private_key.deploy.private_key_pem
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
