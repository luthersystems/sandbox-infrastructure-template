module "storage" {
  source = "github.com/luthersystems/tf-modules.git//aws-platform-ui-storage?ref=v55.13.4"

  luther_project = var.short_project_id
  luther_env     = var.luther_env

  ci_github_repos = [] # TODO:
  #ci_github_repos = [
  #  {
  #    org  = "luthersystems"
  #    repo = local.domain # TODO: this should be a parameter, test env has test. prefix
  #    env  = "prod"
  #  }
  #]

  providers = {
    aws    = aws
    aws.dr = aws
    random = random
  }
}

output "static_bucket" {
  value = module.storage.static_bucket
}

output "static_bucket_arn" {
  value = module.storage.static_bucket_arn
}

output "static_bucket_kms_key_arn" {
  value = module.storage.kms_key_main_arn
}

module "main" {
  source = "github.com/luthersystems/tf-modules.git//aws-platform-ui-main?ref=v55.13.4"

  luther_project           = var.short_project_id
  luther_env               = var.luther_env
  domain                   = local.domain
  kubernetes_version       = var.eks_version
  env_static_s3_bucket_arn = module.storage.static_bucket_arn
  storage_kms_key_arn      = module.storage.kms_key_main_arn
  ansible_relative_path    = "../../ansible"
  eks_worker_count         = var.eks_worker_count
  eks_worker_spot_price    = var.eks_worker_spot_price
  eks_worker_instance_type = var.eks_worker_instance_type

  additional_ansible_facts = {
    domain                                    = local.domain
    luther_ansible_role                       = aws_iam_role.luther_ansible.arn
    luther_project_name                       = var.luther_project_name
    connectorhub_service_account_iam_role_arn = module.connectorhub_service_account_iam_role.arn
    oracle_service_account_iam_role_arn       = module.oracle_service_account_iam_role.arn
  }

  providers = {
    aws.us-east-1 = aws.us-east-1
    aws           = aws
    null          = null
    local         = local
    random        = random
    external      = external
    tls           = tls
  }
}

output "eks_cluster_name" {
  value = module.main.eks_cluster_name
}

output "eks_worker_role_arn" {
  value = module.main.eks_worker_role_arn
}

output "eks_worker_count" {
  value = var.eks_worker_count
}
