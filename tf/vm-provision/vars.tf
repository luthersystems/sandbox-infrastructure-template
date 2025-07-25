variable "short_project_id" {
  type = string
}

variable "luther_env" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "eks_worker_count" {
  type = number
}

variable "ansible_sa_role" {
  type = string
}

variable "bootstrap_state_bucket" {
  type = string
}

variable "bootstrap_state_region" {
  type = string
}

variable "bootstrap_state_env" {
  type = string
}

variable "bootstrap_state_kms_key_id" {
  type = string
}

variable "eks_worker_spot_price" {
  type = string
}

variable "eks_worker_instance_type" {
  type = string
}

variable "eks_version" {
  type = string
}

variable "luther_project_name" {
  type    = string
  default = "app"
}
