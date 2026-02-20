provider "aws" {
  region = var.aws_region

  assume_role {
    role_arn    = local.terraform_role_arn
    external_id = var.aws_external_id != "" ? var.aws_external_id : null
  }
}

provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"

  assume_role {
    role_arn    = local.terraform_role_arn
    external_id = var.aws_external_id != "" ? var.aws_external_id : null
  }
}

provider "github" {
  owner = var.repo_org
}
