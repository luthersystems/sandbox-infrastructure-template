provider "aws" {
  region = var.aws_region

  assume_role {
    role_arn     = "arn:aws:iam::${var.account_id}:role/${var.account_bootstrap_role_name}"
    session_name = "terraform-account-setup"
  }
}
