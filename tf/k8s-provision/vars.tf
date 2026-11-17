variable "aws_region" {
  type = string
}

variable "project_id" {
  type = string
}

variable "short_project_id" {
  type = string
}

# The namespaces k8s-provision creates. The Fabric org namespaces stay a
# fixed list, fabric-org1 to fabric-org5, on purpose (#183):
#   - this stage cannot read the network config: ui-core passes no org count
#     to Terraform (its create-network tfArgs carry only the cloud and EKS
#     settings; num_orgs and org_names go to the ansible inventory only);
#   - module.namespaces creates them with for_each, so a list derived from a
#     smaller network would delete fabric-org2 to fabric-org5, and anything
#     in them, on every existing project's next k8s-provision run.
# So this default is the one source for the namespaces: the ansible org list
# (org_names, which the Fabric plays and ansible/vars/k8s_init_vars.yaml
# read) must stay within fabric-org1 to fabric-org5.
variable "luther_namespaces" {
  type = list(string)
  default = [
    "shiroclient-cli",
    "fabric-orderer",
    "fabric-org1",
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
