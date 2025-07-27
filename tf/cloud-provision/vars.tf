variable "domain" {
  type = string
}

variable "short_project_id" {
  type = string
}

variable "project_id" {
  type = string
}

variable "luther_env" {
  type = string
}

variable "org_name" {
  type = string
}

variable "terraform_sa_role" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "bootstrap_role" {
  type = string
}

variable "create_dns" {
  type    = bool
  default = true
}

variable "github_token" {
  description = "GitHub API token with repo-creation scope"
  type        = string
}
