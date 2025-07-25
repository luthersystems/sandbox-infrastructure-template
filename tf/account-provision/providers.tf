provider "aws" {
  alias  = "platform-account"
  region = var.aws_region
}


provider "aws" {
  alias  = "org-creator"
  region = var.aws_region

  assume_role {
    role_arn     = var.org_creator_role_arn
    session_name = "terraform-org-creator"
  }
}
