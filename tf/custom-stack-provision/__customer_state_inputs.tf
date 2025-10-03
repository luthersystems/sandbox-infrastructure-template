# Inputs needed to read the cloud-provision remote state and choose the role/region
variable "short_project_id" { type = string }
# variable "aws_region" { type = string } # this is already in the customer TF
variable "bootstrap_state_bucket" { type = string }
variable "bootstrap_state_region" { type = string }
variable "bootstrap_state_env" { type = string }
variable "bootstrap_state_kms_key_id" { type = string }
