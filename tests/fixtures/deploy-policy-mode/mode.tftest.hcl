# terraform test for tests/test-deploy-policy-mode.sh (#194).

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::111122223333:policy/io-abc123def456-workload-boundary" }
  }
}
mock_provider "aws" {
  alias = "platform-account"
}
mock_provider "random" {}
mock_provider "github" {}
mock_provider "local" {}
mock_provider "time" {}
mock_provider "tls" {}

variables {
  cloud_provider    = "aws"
  domain            = "abcd1234.apps.example.com"
  short_project_id  = "abcd1234"
  project_id        = "abcd1234-0000-0000-0000-000000000000"
  aws_region        = "us-east-1"
  terraform_sa_role = "arn:aws:iam::999999999999:role/oracle"
  create_dns        = false
}

run "admin_default" {
  command = plan

  assert {
    condition     = jsondecode(module.bootstrap[0].deploy_policy_json).Statement[0].Action == "*"
    error_message = "admin mode must keep the admin-equivalent body."
  }
  assert {
    condition     = length(aws_iam_policy.workload_boundary) == 0 && length(local_file.iam_scope_tfvars) == 0
    error_message = "admin mode must make no workload boundary and no iam_scope file."
  }
  assert {
    condition     = output.iam_scope == null
    error_message = "admin mode must give no iam_scope."
  }
}

run "admin_with_stack_project" {
  command = plan

  variables {
    stack_project = "io-abc123def456"
  }

  assert {
    condition     = jsondecode(module.bootstrap[0].deploy_policy_json).Statement[0].Action == "*"
    error_message = "admin mode must keep the admin-equivalent body with stack_project set."
  }
  assert {
    condition     = length(aws_iam_policy.workload_boundary) == 1 && length(local_file.iam_scope_tfvars) == 0
    error_message = "with stack_project, admin mode keeps the boundary (a project moved back still has roles on it) and writes no iam_scope file."
  }
}

run "scoped" {
  command = apply

  variables {
    deploy_policy_mode = "scoped"
    stack_project      = "io-abc123def456"
  }

  assert {
    condition     = !strcontains(module.bootstrap[0].deploy_policy_json, "$${")
    error_message = "every placeholder in the scoped policy must be filled."
  }
  assert {
    condition     = length(module.bootstrap[0].deploy_policy_json) <= 6144
    error_message = "the scoped policy must fit the IAM limit of 6,144 characters."
  }
  assert {
    condition     = strcontains(module.bootstrap[0].deploy_policy_json, "role/insideout/io-abc123def456/*")
    error_message = "the scoped policy must allow IAM writes on the project path."
  }
  assert {
    condition = anytrue([
      for st in jsondecode(module.bootstrap[0].deploy_policy_json).Statement :
      st.Effect == "Deny" && contains(st.Resource, "arn:aws:iam::111122223333:role/abcd1234-luther-terraform")
    ])
    error_message = "the scoped policy must deny changing the deploy role."
  }
  assert {
    condition = anytrue([
      for st in jsondecode(module.bootstrap[0].deploy_policy_json).Statement :
      st.Effect == "Deny" && contains(st.Resource, "arn:aws:iam::111122223333:policy/abcd1234-luther-terraform-deploy") && contains(st.Resource, aws_iam_policy.workload_boundary[0].arn)
    ])
    error_message = "the scoped policy must deny changing the deploy policy and the boundary."
  }
  assert {
    condition     = aws_iam_policy.workload_boundary[0].name == "io-abc123def456-workload-boundary" && aws_iam_policy.workload_boundary[0].path == "/"
    error_message = "the boundary must be <stack_project>-workload-boundary at path /, off the project path."
  }
  assert {
    condition     = !strcontains(aws_iam_policy.workload_boundary[0].policy, "$${") && strcontains(aws_iam_policy.workload_boundary[0].policy, "role/insideout/io-abc123def456/*")
    error_message = "the boundary placeholders must be filled."
  }
  assert {
    condition     = aws_iam_policy.workload_boundary[0].tags["Project"] == var.project_id
    error_message = "the boundary must carry project_id, not the stack's Project tag."
  }
  assert {
    condition = jsondecode(local_file.iam_scope_tfvars[0].content) == {
      iam_scope = {
        path                 = "/insideout/io-abc123def456/"
        permissions_boundary = aws_iam_policy.workload_boundary[0].arn
      }
    }
    error_message = "the iam_scope file must give the composed stack the path and the boundary."
  }
  assert {
    condition     = endswith(local_file.iam_scope_tfvars[0].filename, "/auto-vars/iam_scope.auto.tfvars.json")
    error_message = "the iam_scope file must go to tf/auto-vars, which custom-stack-provision loads."
  }
}

run "scoped_without_stack_project_fails" {
  command = plan

  variables {
    deploy_policy_mode = "scoped"
  }

  expect_failures = [aws_iam_policy.insideout_deploy_boundary]
}

run "unknown_mode_fails" {
  command = plan

  variables {
    deploy_policy_mode = "readonly"
  }

  expect_failures = [var.deploy_policy_mode]
}
