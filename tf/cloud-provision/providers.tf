provider "aws" {
  region = var.aws_region

  assume_role {
    role_arn = var.bootstrap_role
  }
}

provider "aws" {
  alias  = "platform-account"
  region = var.aws_region
}
