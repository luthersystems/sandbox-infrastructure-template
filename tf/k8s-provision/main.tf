locals {
  map_roles = [
    {
      rolearn  = local.eks_worker_role_arn
      username = "system:node:{{EC2PrivateDNSName}}"

      groups = [
        "system:bootstrappers",
        "system:nodes",
      ]
    },
    {
      rolearn  = local.luther_ansible_role
      username = "luther:admin"

      groups = [
        "system:masters",
      ]
    },
  ]

  namespaces = distinct(compact(concat(
    var.luther_namespaces,
    [var.luther_project_name]
  )))
}

resource "kubernetes_config_map_v1_data" "aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  data = {
    mapRoles = yamlencode(local.map_roles)
  }

  force = true
}

module "namespaces" {
  source = "./namespaces"

  project_id        = var.project_id
  luther_namespaces = local.namespaces

  providers = {
    kubernetes = kubernetes
  }
}
