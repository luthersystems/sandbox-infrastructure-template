# This file is remove unused vars warnings, but they are not used  
# in this project.

variable "bootstrap_role" {
  type    = string
  default = ""
}

variable "account_id" {
  type    = string
  default = ""
}

variable "account_bootstrap_role_name" {
  type    = string
  default = ""
}

variable "account_email" {
  type    = string
  default = ""
}

variable "account_name" {
  type    = string
  default = ""
}

variable "ansible_sa_role" {
  type    = string
  default = ""
}

variable "billing_access" {
  type    = string
  default = ""
}

variable "create_dns" {
  type    = bool
  default = false
}

variable "domain" {
  type    = string
  default = ""
}

variable "eks_version" {
  type    = string
  default = ""
}

variable "eks_worker_count" {
  type    = number
  default = 0
}

variable "eks_worker_instance_type" {
  type    = string
  default = ""
}

variable "eks_worker_spot_price" {
  type    = string
  default = ""
}

variable "luther_env" {
  type    = string
  default = ""
}

variable "org_creator_role_arn" {
  type    = string
  default = ""
}

variable "org_name" {
  type    = string
  default = ""
}

variable "parent_ou_name" {
  type    = string
  default = ""
}

variable "terraform_sa_role" {
  type    = string
  default = ""
}
