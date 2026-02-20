terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

# ============================================================================
# AWS Providers (used when cloud_provider = aws)
# ============================================================================

provider "aws" {
  region = var.cloud_provider == "aws" ? var.aws_region : "us-west-2"
  assume_role {
    role_arn    = var.cloud_provider == "aws" ? local.terraform_role_arn : null
    external_id = var.cloud_provider == "aws" ? var.aws_external_id : null
  }
}

# CloudFront/WAF needs us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  assume_role {
    role_arn    = var.cloud_provider == "aws" ? local.terraform_role_arn : null
    external_id = var.cloud_provider == "aws" ? var.aws_external_id : null
  }
}

# ============================================================================
# GCP Provider (used when cloud_provider = gcp)
# ============================================================================

provider "google" {
  project = var.cloud_provider == "gcp" ? var.gcp_project_id : null
  region  = var.cloud_provider == "gcp" ? var.gcp_region : null
  # Credentials are provided via GOOGLE_APPLICATION_CREDENTIALS env var
  # set by shell_utils.sh / run-with-creds.sh
}
