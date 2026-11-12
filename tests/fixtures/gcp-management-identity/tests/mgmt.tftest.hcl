# terraform test for the durable GCP management identity (issue #63).
# tests/test-gcp-management-identity.sh copies this file, with the real
# tf/cloud-provision/gcp-resources.tf.tmpl, into a scratch module and runs it.
# The script lists what each run checks and why.

mock_provider "google" {
  # Fixed emails so the assertions below can compare exact values.
  override_resource {
    target = google_service_account.insideout_management
    values = {
      email = "insideout-mgmt-abcd1234@cust-proj.iam.gserviceaccount.com"
      name  = "projects/cust-proj/serviceAccounts/insideout-mgmt-abcd1234@cust-proj.iam.gserviceaccount.com"
    }
  }
  override_resource {
    target = google_service_account.insideout_inspector
    values = {
      email = "insideout-inspector-abcd1234@cust-proj.iam.gserviceaccount.com"
      name  = "projects/cust-proj/serviceAccounts/insideout-inspector-abcd1234@cust-proj.iam.gserviceaccount.com"
    }
  }
}
mock_provider "local" {}

variables {
  domain           = "example.com"
  short_project_id = "abcd1234"
  project_id       = "abcd1234-project"
  cloud_provider   = "gcp"
  gcp_project_id   = "cust-proj"
  gcp_region       = "us-central1"
  # The stage reads the uploaded key only for its client_email. Built here,
  # not written as a base64 literal: the secrets scan reads a literal one as
  # a leaked key.
  gcp_credentials_b64 = base64encode(jsonencode({ client_email = "deployer@cust-proj.iam.gserviceaccount.com" }))
}

run "management_identity" {
  command = apply

  assert {
    condition     = google_service_account.insideout_management.account_id == "insideout-mgmt-abcd1234"
    error_message = "management account ID is not insideout-mgmt-<short_project_id>; ui-core derives it from that name"
  }

  assert {
    condition     = length(google_service_account.insideout_management.account_id) <= 30
    error_message = "management account ID is longer than the GCP limit of 30 characters"
  }

  # The inspector ID is 28 characters for an 8-character short_project_id, so
  # a longer prefix shows up here first.
  assert {
    condition     = length(google_service_account.insideout_inspector.account_id) <= 30
    error_message = "inspector account ID is longer than the GCP limit of 30 characters"
  }

  assert {
    condition     = google_service_account.insideout_management.account_id != google_service_account.insideout_inspector.account_id
    error_message = "management and inspector accounts must be separate identities"
  }

  assert {
    condition     = google_service_account.insideout_management.project == "cust-proj"
    error_message = "management account is not in the customer's GCP project"
  }

  assert {
    condition     = google_project_iam_member.management_owner.role == "roles/owner" && google_project_iam_member.management_owner.project == "cust-proj"
    error_message = "management account must hold roles/owner on the customer's project for steady-state plan/apply"
  }

  assert {
    condition     = google_project_iam_member.management_owner.member == "serviceAccount:insideout-mgmt-abcd1234@cust-proj.iam.gserviceaccount.com"
    error_message = "roles/owner is not granted to the management account"
  }

  assert {
    condition     = google_service_account_iam_member.management_token_creator.role == "roles/iam.serviceAccountTokenCreator"
    error_message = "management token-creator grant has the wrong role"
  }

  assert {
    condition     = google_service_account_iam_member.management_token_creator.member == "serviceAccount:deployer@cust-proj.iam.gserviceaccount.com"
    error_message = "the deployment identity (client_email of the uploaded key) cannot impersonate the management account"
  }

  assert {
    condition     = google_service_account_iam_member.management_token_creator.service_account_id == google_service_account.insideout_management.name
    error_message = "token-creator grant is not on the management account"
  }

  assert {
    condition     = output.gcp_management_sa_email == "insideout-mgmt-abcd1234@cust-proj.iam.gserviceaccount.com"
    error_message = "output gcp_management_sa_email does not return the management account email"
  }

  assert {
    condition     = output.gcp_management_sa_id == "insideout-mgmt-abcd1234"
    error_message = "output gcp_management_sa_id does not return the management account ID"
  }

  # The inspector must stay read-only and unchanged (issue #63 acceptance).
  assert {
    condition     = google_project_iam_member.inspector_viewer.role == "roles/viewer" && google_project_iam_member.inspector_viewer.member == "serviceAccount:insideout-inspector-abcd1234@cust-proj.iam.gserviceaccount.com"
    error_message = "inspector account lost roles/viewer"
  }

  assert {
    condition     = output.gcp_inspector_sa_email != output.gcp_management_sa_email
    error_message = "inspector and management outputs point at the same account"
  }
}

# Steady state: later runs set gcp_impersonate_service_account to the
# management account. The grant must still go to the uploaded key's identity,
# not to the impersonated account, or the impersonation chain would have no
# source credential that holds the grant.
run "steady_state_impersonation" {
  command = apply

  variables {
    gcp_impersonate_service_account = "insideout-mgmt-abcd1234@cust-proj.iam.gserviceaccount.com"
  }

  assert {
    condition     = google_service_account_iam_member.management_token_creator.member == "serviceAccount:deployer@cust-proj.iam.gserviceaccount.com"
    error_message = "with impersonation set, the token-creator grant no longer goes to the uploaded key's client_email"
  }

  assert {
    condition     = output.gcp_management_sa_email == "insideout-mgmt-abcd1234@cust-proj.iam.gserviceaccount.com"
    error_message = "with impersonation set, output gcp_management_sa_email changed"
  }
}
