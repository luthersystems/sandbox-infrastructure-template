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
  description = "AWS Region in which to operate"
  type        = string
}

variable "account_id" {
  description = "ID of the newly created AWS account"
  type        = string
}

variable "account_bootstrap_role_name" {
  description = "Name of the bootstrap IAM role in the new account"
  type        = string
}

variable "terraform_sa_role" {
  description = "Role ARN of the service account running terraform."
  type        = string
}

variable "additional_terraform_sa_roles" {
  description = "List of IAM role ARNs from platform accounts (e.g., Argo Terraform roles) allowed to assume the admin role"
  type        = list(string)
  default     = []
}
