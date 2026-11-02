# Provider requirements for the scratch module that
# tests/test-gcp-management-identity.sh builds around
# tf/cloud-provision/gcp-resources.tf.tmpl. That file uses only google and
# local, so the test needs these two instead of providers-gcp.tf.tmpl. The
# stage's lock file pins the versions (google 6.10.0), as on a deploy.
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.1"
    }
  }
}
