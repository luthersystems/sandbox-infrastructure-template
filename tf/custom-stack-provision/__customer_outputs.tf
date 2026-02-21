# Outputs for custom-stack-provision.
#
# This file uses the __customer_ prefix so it survives prepare-custom-stack.sh
# rsync operations. Outputs use try() to gracefully handle modules that are
# conditionally disabled (count = 0).

# ============================================================================
# VPC
# ============================================================================

output "vpc_id" {
  description = "VPC ID created by the custom stack (empty when module is disabled)"
  value       = try(module.aws_vpc[0].vpc_id, "")
}

# ============================================================================
# EC2
# ============================================================================

output "instance_id" {
  description = "EC2 instance ID created by the custom stack (empty when module is disabled)"
  value       = try(module.aws_ec2[0].instance_id, "")
}

output "public_ip" {
  description = "Public IP address of the EC2 instance (empty when module is disabled)"
  value       = try(module.aws_ec2[0].public_ip, "")
}

output "private_ip" {
  description = "Private IP address of the EC2 instance (empty when module is disabled)"
  value       = try(module.aws_ec2[0].private_ip, "")
}

# ============================================================================
# RDS
# ============================================================================

output "db_address" {
  description = "RDS database endpoint address (empty when module is disabled)"
  value       = try(module.aws_rds[0].db_address, "")
}

output "db_port" {
  description = "RDS database port (empty when module is disabled)"
  value       = try(module.aws_rds[0].db_port, "")
}

# ============================================================================
# Secrets Manager
# ============================================================================

output "secret_arns" {
  description = "List of Secrets Manager secret ARNs (empty when module is disabled)"
  value       = try(module.secretsmanager[0].secret_arns, [])
}
