# /add-terraform-resource -- Add a Terraform Resource

## Trigger

User asks to add a new Terraform resource, IAM role, security group, or other infrastructure component to a specific stage.

## Workflow

1. **Identify the correct stage:**

   | Stage | Purpose | Directory |
   |-------|---------|-----------|
   | account-provision | AWS Organization account creation | `tf/account-provision/` |
   | account-setup | IAM role bootstrap | `tf/account-setup/` |
   | cloud-provision | Networking, DNS, S3/GCS, KMS | `tf/cloud-provision/` |
   | vm-provision | EKS workers, SA IAM roles | `tf/vm-provision/` |
   | k8s-provision | EKS cluster config, RBAC | `tf/k8s-provision/` |
   | custom-stack-provision | Customer-specific overlay | `tf/custom-stack-provision/` |

2. **Read existing files** in the stage directory to understand patterns:
   ```bash
   ls tf/<stage>/
   ```
   Read related `.tf` files to see variable names, locals, and naming conventions.

3. **Check if the resource needs dual-cloud support.** If yes, chain to `/add-cloud-resource`.

4. **Add the resource** following these conventions:
   - Use existing `locals` for computed values (e.g., `local.is_aws`, `local.is_gcp`)
   - Reference variables from `tf/auto-vars/common.auto.tfvars.json` when available
   - Add appropriate tags/labels:
     ```hcl
     tags = {
       Project   = var.project_id
       ManagedBy = "terraform"
       Purpose   = "<descriptive-purpose>"
     }
     ```

5. **Add required variables** to `variables.tf` in the stage directory (if not already defined).

6. **Add outputs** for any values other stages or Ansible might need:
   ```hcl
   output "resource_arn" {
     description = "ARN of the new resource"
     value       = aws_thing.example.arn
   }
   ```

7. **Validate:**
   ```bash
   cd tf/<stage> && terraform validate
   ```

## Module References

When using shared modules, pin the version:
```hcl
module "example" {
  source = "github.com/luthersystems/tf-modules.git//modules/example?ref=v1.2.3"
}
```

## Anti-patterns

- Do not add resources to the wrong stage
- Do not hardcode account IDs, project IDs, or region names
- Do not forget to add outputs for cross-stage references
- Do not use unpinned module sources (always use `?ref=vX.Y.Z`)
- Do not create a new `.tf` file when the resource logically belongs in an existing one

## Checklist

- [ ] Correct stage identified
- [ ] Existing patterns in stage reviewed
- [ ] Resource uses appropriate locals and variables
- [ ] Tags/labels applied
- [ ] Variables defined if new
- [ ] Outputs added for cross-stage references
- [ ] `terraform validate` passes (if init'd)
