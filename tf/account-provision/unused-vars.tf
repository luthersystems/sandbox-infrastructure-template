# This file is remove unused vars warnings, but they are not used  
# in this project.

variable "project_id" {
  type    = string
  default = ""
}

variable "account_id" {
  type    = string
  default = ""
}

variable "bootstrap_role" {
  description = "ARN of the bootstrap IAM role"
  type        = string
  default     = ""
}

variable "ansible_sa_role" {
  description = "ARN of the Ansible service account role"
  type        = string
  default     = ""
}

variable "bootstrap_state_bucket" {
  description = "S3 bucket for bootstrap state"
  type        = string
  default     = ""
}

variable "bootstrap_state_env" {
  description = "Environment name for bootstrap state"
  type        = string
  default     = ""
}

variable "bootstrap_state_kms_key_id" {
  description = "KMS Key ARN for bootstrap state encryption"
  type        = string
  default     = ""
}

variable "bootstrap_state_region" {
  description = "AWS region for bootstrap state"
  type        = string
  default     = ""
}

variable "create_dns" {
  description = "Whether to create DNS records"
  type        = bool
  default     = false
}

variable "domain" {
  description = "Domain name for the project"
  type        = string
  default     = ""
}

variable "eks_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = ""
}

variable "eks_worker_count" {
  description = "Number of EKS worker nodes"
  type        = number
  default     = 0
}

variable "eks_worker_instance_type" {
  description = "EC2 instance type for EKS workers"
  type        = string
  default     = ""
}

variable "eks_worker_spot_price" {
  description = "Spot price for EKS worker nodes"
  type        = string
  default     = ""
}

variable "terraform_sa_role" {
  description = "ARN of the Terraform service account role"
  type        = string
  default     = ""
}
