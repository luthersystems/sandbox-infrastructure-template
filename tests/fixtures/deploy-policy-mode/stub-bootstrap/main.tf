# Stub of tf-modules aws-platform-ui-bootstrap for
# tests/test-deploy-policy-mode.sh: the same inputs, the outputs the stage
# reads, and deploy_policy_json back so the test can check it.

terraform {
  required_providers {
    aws    = { source = "hashicorp/aws" }
    random = { source = "hashicorp/random" }
  }
}

variable "project" { type = any }
variable "env" { type = any }
variable "org_name" { type = any }
variable "domain" { type = any }
variable "admin_principals" { type = any }
variable "admin_role_name" { type = string }
variable "create_state_bucket" { type = any }
variable "create_dns" { type = any }
variable "kms_alias_suffix" { type = any }
variable "deploy_policy_json" { type = string }
variable "permissions_boundary_arn" { type = string }

# The real module counts the deploy policy on deploy_policy_json, so an
# unknown body fails the plan ("Invalid count argument"). The stub does the
# same, so a body that is known only at apply fails this test too.
resource "terraform_data" "deploy" {
  count = var.deploy_policy_json != "" ? 1 : 0
  input = var.deploy_policy_json
}

output "admin_role" { value = "arn:aws:iam::111122223333:role/${var.admin_role_name}" }
output "aws_kms_key_id" { value = "key" }
output "aws_s3_bucket_tfstate" { value = "bucket" }
output "aws_route53_zone_name_servers" { value = ["ns"] }
output "domain" { value = var.domain }
output "deploy_policy_json" { value = var.deploy_policy_json }
