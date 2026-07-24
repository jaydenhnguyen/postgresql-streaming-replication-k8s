output "instance_id" {
  description = "ID of the EC2 / kind host"
  value       = aws_instance.kind_host.id
}

output "public_ip" {
  description = "Public IP address of the EC2 / kind host"
  value       = aws_instance.kind_host.public_ip
}

output "private_ip" {
  description = "Private IP address of the EC2 / kind host"
  value       = aws_instance.kind_host.private_ip
}

output "public_dns" {
  description = "Public DNS name of the EC2 / kind host"
  value       = aws_instance.kind_host.public_dns
}

output "ssh_command" {
  description = "Example SSH command (replace private key path as needed)"
  value       = "ssh -i <path-to-private-key> ec2-user@${aws_instance.kind_host.public_ip}"
}
