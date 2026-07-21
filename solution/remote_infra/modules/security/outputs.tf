output "ec2_sg_id" {
  description = "Security group ID for the EC2 / kind host"
  value       = aws_security_group.ec2.id
}

output "ec2_sg_name" {
  description = "Security group name for the EC2 / kind host"
  value       = aws_security_group.ec2.name
}
