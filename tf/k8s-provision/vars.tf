variable "aws_region" {
  type = string
}

variable "project_id" {
  type = string
}

variable "short_project_id" {
  type = string
}

variable "luther_namespaces" {
  type = list(string)
  default = [
    "shiroclient-cli",
    "fabric-orderer",
    "fabric-org1",
    # TODO: dynamically populate org list
    "fabric-org2",
    "fabric-org3",
    "fabric-org4",
    "fabric-org5",
  ]
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

variable "luther_project_name" {
  type    = string
  default = "app"
}

variable "aws_external_id" {
  description = "ExternalId for confused-deputy protection when assuming cross-account roles"
  type        = string
  default     = ""
}
