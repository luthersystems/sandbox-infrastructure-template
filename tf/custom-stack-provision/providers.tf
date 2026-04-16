# Cloud-specific provider configurations are in providers-{cloud}.tf.tmpl files.
# At deploy time, _selectProviderFiles() copies the active cloud's template
# into providers-{cloud}.tf (which is gitignored).
terraform {
  required_version = ">= 1.5"
}
