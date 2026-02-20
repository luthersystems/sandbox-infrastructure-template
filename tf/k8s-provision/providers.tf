provider "aws" {
  region = var.aws_region

  assume_role {
    role_arn    = local.terraform_role_arn
    external_id = var.aws_external_id != "" ? var.aws_external_id : null
  }
}

data "aws_eks_cluster" "main" {
  name = local.eks_cluster_name
}

data "aws_eks_cluster_auth" "main" {
  name = local.eks_cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
}
