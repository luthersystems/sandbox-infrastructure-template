module "connectorhub_service_account_iam_role" {
  source = "github.com/luthersystems/tf-modules//eks-service-account-iam-role?ref=v55.13.4"

  luther_project = var.short_project_id
  aws_region     = var.aws_region
  luther_env     = var.luther_env
  component      = "main"

  oidc_provider_name = module.main.oidc_provider_name
  oidc_provider_arn  = module.main.oidc_provider_arn
  service_account    = "umbrella-connectorhub"
  k8s_namespace      = var.luther_project_name

  providers = {
    aws = aws
  }
}

output "connectorhub_service_account_role_arn" {
  value = module.connectorhub_service_account_iam_role.arn
}

module "oracle_service_account_iam_role" {
  source = "github.com/luthersystems/tf-modules//eks-service-account-iam-role?ref=v55.13.4"

  luther_project = var.short_project_id
  aws_region     = var.aws_region
  luther_env     = var.luther_env
  component      = "main"

  oidc_provider_name = module.main.oidc_provider_name
  oidc_provider_arn  = module.main.oidc_provider_arn
  service_account    = "umbrella-oracle"
  k8s_namespace      = var.luther_project_name

  providers = {
    aws = aws
  }
}

output "oracle_service_account_role_arn" {
  value = module.oracle_service_account_iam_role.arn
}

output "oidc_provider_name" {
  value = module.main.oidc_provider_name
}

output "oidc_provider_arn" {
  value = module.main.oidc_provider_arn
}

output "oidc_provider_thumbprints" {
  value = module.main.oidc_provider_thumbprints
}
