terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  assume_role { role_arn = local.terraform_role_arn }
}

# CloudFront/WAF needs us-east-1
provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"
  assume_role { role_arn = local.terraform_role_arn }
}
