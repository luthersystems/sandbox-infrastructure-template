resource "github_repository" "infra" {
  name        = "${var.short_project_id}-infra"
  description = "Infrastructure repo for ${var.short_project_id}"
  visibility  = "private"

  // optional settings:
  has_issues = true
  has_wiki   = false
}

output "repo_clone_url" {
  description = "HTTPS clone URL of the newly created repo"
  value       = github_repository.infra.clone_url
}

# New file: tf/repo-provision/deploy_key.tf

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
