variable "short_project_id" {
  type = string
}

variable "luther_env" {
  type = string
}

variable "org_name" {
  type = string
}

variable "aws_region" {
  description = "AWS Region in which to create the account"
  type        = string
}

variable "account_name" {
  description = "A friendly name for the new account"
  type        = string
}

variable "account_email" {
  description = "Root email address for the new AWS account"
  type        = string
}

variable "parent_ou_name" {
  description = "Organization Unit Name under which to place this account"
  type        = string
}

variable "account_bootstrap_role_name" {
  description = "Name of the initial IAM role to create in the new account"
  type        = string
}

variable "billing_access" {
  description = "Whether the account should have billing access ('ALLOW' or 'DENY')"
  type        = string
  default     = "DENY"
}

variable "org_creator_role_arn" {
  description = "ARN of the org-creator role (in root account) to assume when creating new AWS accounts"
  type        = string
}
