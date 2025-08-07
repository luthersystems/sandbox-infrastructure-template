locals {
  ci_role_arn = module.storage.ci_role_arn
}

output "ci_role_arn" {
  value = local.ci_role_arn
}

resource "github_actions_variable" "aws_ci_role_arn" {
  repository    = var.repo_name
  variable_name = "AWS_ROLE_ARN"
  value         = local.ci_role_arn
}
