resource "aws_iam_role" "luther_ansible" {
  name               = "${var.short_project_id}-luther-ansible"
  description        = "Provides ansible access to EKS cluster"
  assume_role_policy = data.aws_iam_policy_document.ansible_assume_role.json
}

data "aws_iam_policy_document" "ansible_assume_role" {
  statement {
    sid = "allowLutherAnsible"

    principals {
      type        = "AWS"
      identifiers = [var.ansible_sa_role]
    }

    actions = ["sts:AssumeRole"]
  }
}

output "luther_ansible_role" {
  value = aws_iam_role.luther_ansible.arn
}

resource "aws_iam_role_policy" "luther_ansible" {
  name   = "EKSAccess"
  role   = aws_iam_role.luther_ansible.name
  policy = data.aws_iam_policy_document.luther_ansible.json
}

data "aws_iam_policy_document" "luther_ansible" {
  statement {
    sid       = "describeCluster"
    actions   = ["eks:DescribeCluster"]
    resources = [module.main.eks_cluster_arn]
  }
}
