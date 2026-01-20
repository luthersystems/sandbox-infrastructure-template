# InsideOut Inspector Role
#
# This file creates read-only inspector credentials for InsideOut:
# - AWS: IAM role that trusts the Terraform SA role (double-hop AssumeRole)
# - GCP: Service account with viewer permissions (token impersonation)

locals {
  # AWS inspector role name
  inspector_role_name = "insideout-inspector-${var.project_id}"

  # GCP inspector service account ID (max 30 chars, lowercase, hyphens allowed)
  gcp_inspector_sa_id = "insideout-inspector-${var.short_project_id}"

  # Extract deployment SA email from credentials for token creator binding
  gcp_deployment_sa_email = local.is_gcp ? jsondecode(base64decode(var.gcp_credentials_b64)).client_email : ""
}

data "aws_iam_policy_document" "inspector_assume" {
  count = local.is_aws ? 1 : 0

  statement {
    sid    = "AllowTerraformSAAssume"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [var.terraform_sa_role]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "insideout_inspector" {
  count = local.is_aws ? 1 : 0

  name                 = local.inspector_role_name
  description          = "Read-only role for InsideOut infrastructure inspection"
  assume_role_policy   = data.aws_iam_policy_document.inspector_assume[0].json
  max_session_duration = 3600 # 1 hour

  tags = {
    Project   = var.project_id
    ManagedBy = "terraform"
    Purpose   = "insideout-inspection"
  }
}

resource "aws_iam_role_policy_attachment" "inspector_readonly" {
  count = local.is_aws ? 1 : 0

  role       = aws_iam_role.insideout_inspector[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ============================================================================
# GCP Inspector Service Account (only created when cloud_provider = gcp)
# ============================================================================

# Create a dedicated read-only service account for inspection
resource "google_service_account" "insideout_inspector" {
  count = local.is_gcp ? 1 : 0

  account_id   = local.gcp_inspector_sa_id
  display_name = "InsideOut Inspector - ${var.project_id}"
  description  = "Read-only service account for InsideOut infrastructure inspection"
  project      = var.gcp_project_id
}

# Grant Viewer role (read-only access to most resources)
resource "google_project_iam_member" "inspector_viewer" {
  count = local.is_gcp ? 1 : 0

  project = var.gcp_project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.insideout_inspector[0].email}"
}

# Grant Storage Object Viewer for GCS bucket contents
resource "google_project_iam_member" "inspector_storage_viewer" {
  count = local.is_gcp ? 1 : 0

  project = var.gcp_project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.insideout_inspector[0].email}"
}

# Grant Secret Manager Viewer for secret metadata (not values)
resource "google_project_iam_member" "inspector_secretmanager_viewer" {
  count = local.is_gcp ? 1 : 0

  project = var.gcp_project_id
  role    = "roles/secretmanager.viewer"
  member  = "serviceAccount:${google_service_account.insideout_inspector[0].email}"
}

# Allow the deployment SA to generate tokens for the inspector SA
# This enables Oracle to impersonate the inspector SA for read-only access
resource "google_service_account_iam_member" "inspector_token_creator" {
  count = local.is_gcp ? 1 : 0

  service_account_id = google_service_account.insideout_inspector[0].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${local.gcp_deployment_sa_email}"
}

# ============================================================================
# Outputs
# ============================================================================

output "inspector_role_arn" {
  description = "ARN of the InsideOut inspector role (AWS only)"
  value       = local.is_aws ? aws_iam_role.insideout_inspector[0].arn : ""
}

output "inspector_role_name" {
  description = "Name of the InsideOut inspector role (AWS only)"
  value       = local.is_aws ? aws_iam_role.insideout_inspector[0].name : ""
}

output "gcp_inspector_sa_email" {
  description = "Email of the GCP inspector service account (GCP only)"
  value       = local.is_gcp ? google_service_account.insideout_inspector[0].email : ""
}

output "gcp_inspector_sa_id" {
  description = "ID of the GCP inspector service account (GCP only)"
  value       = local.is_gcp ? google_service_account.insideout_inspector[0].account_id : ""
}


