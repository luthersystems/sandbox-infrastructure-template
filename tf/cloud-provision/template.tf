locals {
  state_workspace_vm  = "vm"
  state_workspace_k8s = "k8s"

  state_kms_key_id = module.bootstrap.aws_kms_key_id
  state_role_arn   = local.admin_role_arn

  state = {
    bucket = module.bootstrap.aws_s3_bucket_tfstate
    region = var.aws_region
  }

  state_backend_vm = merge(local.state, {
    workspace_key_prefix = local.state_workspace_vm
    key                  = format("terraform_%s.tfstate", local.state_workspace_vm)
    kms_key_id           = local.state_kms_key_id,
    role_arn             = local.state_role_arn,
  })

  state_backend_k8s = merge(local.state, {
    workspace_key_prefix = local.state_workspace_k8s
    key                  = format("terraform_%s.tfstate", local.state_workspace_k8s)
    kms_key_id           = local.state_kms_key_id,
    role_arn             = local.state_role_arn,
  })
}

output "state_workspace_vm" {
  value = local.state_workspace_vm
}

output "state_backend_vm" {
  value = local.state_backend_vm
}

resource "local_file" "vm_backend_template" {
  content  = templatefile("backend.tf.tftpl", local.state_backend_vm)
  filename = "${path.module}/../vm-provision/backend.tf"
}

resource "local_file" "k8s_backend_template" {
  content  = templatefile("backend.tf.tftpl", local.state_backend_k8s)
  filename = "${path.module}/../k8s-provision/backend.tf"
}
