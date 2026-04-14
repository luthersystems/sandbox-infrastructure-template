# Cloud-specific provider configurations are in providers-{cloud}.tf.tmpl files.
# At deploy time, _selectProviderFiles() copies the active cloud's template
# into providers-{cloud}.tf (which is gitignored).
#
# required_providers stays here so terraform validate works in CI without
# needing a deployed .tf.tmpl copy.
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
