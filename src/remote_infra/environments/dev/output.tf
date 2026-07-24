output "kind_host_public_ip" {
  description = "Public IP of the EC2 kind host"
  value       = module.ec2.public_ip
}

output "kind_host_ssh" {
  description = "SSH hint for the kind host (Amazon Linux uses ec2-user)"
  value       = module.ec2.ssh_command
}
