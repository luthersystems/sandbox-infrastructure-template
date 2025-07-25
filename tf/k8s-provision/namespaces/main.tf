resource "kubernetes_namespace" "luther" {
  for_each = toset(var.luther_namespaces)

  metadata {
    name = each.key
    annotations = {
      name = "luther"
    }
    labels = {
      luther-project-id = var.project_id
    }
  }
}
