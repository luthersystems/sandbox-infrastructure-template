data "terraform_remote_state" "vm_provision" {
  backend = "s3"

  config = {
    bucket               = data.terraform_remote_state.cloud_provision.outputs.state_backend_vm.bucket
    key                  = data.terraform_remote_state.cloud_provision.outputs.state_backend_vm.key
    region               = var.aws_region
    workspace_key_prefix = data.terraform_remote_state.cloud_provision.outputs.state_backend_vm.workspace_key_prefix
    kms_key_id           = data.terraform_remote_state.cloud_provision.outputs.state_backend_vm.kms_key_id

    assume_role = {
      role_arn = data.terraform_remote_state.cloud_provision.outputs.state_backend_vm.role_arn
    }
  }
}

locals {
  eks_cluster_name    = data.terraform_remote_state.vm_provision.outputs.eks_cluster_name
  eks_worker_role_arn = data.terraform_remote_state.vm_provision.outputs.eks_worker_role_arn
  luther_ansible_role = data.terraform_remote_state.vm_provision.outputs.luther_ansible_role
}
