locals {
  repo_name = "${var.short_project_id}-infra"
}

resource "github_repository" "infra" {
  name        = local.repo_name
  description = "Infrastructure repo for ${var.short_project_id}"
  visibility  = "private"

  // optional settings:
  has_issues = true
  has_wiki   = false
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
    repo_org           = var.github_owner
  })
}

resource "github_actions_variable" "aws_region" {
  repository    = github_repository.infra.name
  variable_name = "AWS_REGION"
  value         = var.aws_region != "" ? var.aws_region : "us-west-2"
}
