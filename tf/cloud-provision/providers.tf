# ============================================================================
# AWS Providers (used when cloud_provider = aws)
# ============================================================================

provider "aws" {
  region = var.cloud_provider == "aws" ? var.aws_region : "us-west-2"

  assume_role {
    role_arn    = var.cloud_provider == "aws" ? var.bootstrap_role : null
    external_id = var.cloud_provider == "aws" && var.aws_external_id != "" ? var.aws_external_id : null
  }
}

provider "aws" {
  alias  = "platform-account"
  region = var.cloud_provider == "aws" ? var.aws_region : "us-west-2"
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

# ============================================================================
# GitHub Provider (used for both clouds)
# ============================================================================

provider "github" {
  owner = var.repo_org
}
