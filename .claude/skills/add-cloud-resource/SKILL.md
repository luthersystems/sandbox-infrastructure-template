# /add-cloud-resource -- Add a Dual-Cloud Resource

## Trigger

User asks to add a resource that must work on both AWS and GCP, or asks to follow the dual-cloud pattern.

## Workflow

1. **Identify the correct stage** (see `/add-terraform-resource` for the stage table).

2. **Read the dual-cloud pattern** from `tf/cloud-provision/inspector.tf` as the canonical example. Key patterns:

   **Locals for cloud detection:**
   ```hcl
   locals {
     is_aws = var.cloud_provider == "aws"
     is_gcp = var.cloud_provider == "gcp"
   }
   ```
   These are typically already defined in the stage -- reuse them, don't redefine.

3. **Create AWS resources** with conditional count:
   ```hcl
   resource "aws_<type>" "<name>" {
     count = local.is_aws ? 1 : 0

     # resource configuration...

     tags = {
       Project   = var.project_id
       ManagedBy = "terraform"
       Purpose   = "<purpose>"
     }
   }
   ```

4. **Create matching GCP resources** with conditional count:
   ```hcl
   resource "google_<type>" "<name>" {
     count = local.is_gcp ? 1 : 0

     project = var.gcp_project_id
     # resource configuration...
   }
   ```

5. **Add conditional outputs:**
   ```hcl
   output "resource_id" {
     description = "Resource ID (AWS)"
     value       = local.is_aws ? aws_<type>.<name>[0].id : ""
   }

   output "gcp_resource_id" {
     description = "Resource ID (GCP)"
     value       = local.is_gcp ? google_<type>.<name>[0].id : ""
   }
   ```

6. **Add data sources** if needed (also with conditional count):
   ```hcl
   data "aws_iam_policy_document" "<name>" {
     count = local.is_aws ? 1 : 0
     # ...
   }
   ```
   Reference with index: `data.aws_iam_policy_document.<name>[0].json`

7. **Add variables** if new cloud-specific inputs are needed. Check if they already exist in `variables.tf`.

8. **Validate:**
   ```bash
   cd tf/<stage> && terraform validate
   ```

## Reference: inspector.tf Pattern

The `tf/cloud-provision/inspector.tf` file demonstrates the complete dual-cloud pattern:
- AWS IAM role + policy attachment (count = `local.is_aws ? 1 : 0`)
- GCP service account + IAM member bindings (count = `local.is_gcp ? 1 : 0`)
- Conditional outputs that return empty string for the inactive cloud
- Local variables for computed names
- Data sources with conditional count

## Anti-patterns

- Do not redefine `local.is_aws`/`local.is_gcp` if they already exist in the stage
- Do not forget the `[0]` index when referencing conditionally-counted resources
- Do not create AWS-only or GCP-only resources when both clouds need them
- Do not hardcode project IDs -- use `var.gcp_project_id` or `var.project_id`
- Do not forget to add `project` to GCP resources

## Checklist

- [ ] Correct stage identified
- [ ] `local.is_aws`/`local.is_gcp` reused (not redefined)
- [ ] AWS resource with `count = local.is_aws ? 1 : 0`
- [ ] GCP resource with `count = local.is_gcp ? 1 : 0`
- [ ] Both resources have equivalent functionality
- [ ] Conditional outputs for both clouds
- [ ] Resources reference with `[0]` index
- [ ] `terraform validate` passes
