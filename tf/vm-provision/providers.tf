provider "aws" {
  region = var.aws_region

  assume_role {
    role_arn = local.terraform_role_arn
  }
}

provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"

  assume_role {
    role_arn = local.terraform_role_arn
  }
}

provider "github" {
  owner = var.repo_org
}
