output "kind_host_public_ip" {
  description = "Public IP of the EC2 kind host"
  value       = module.ec2.public_ip
}

output "kind_host_ssh" {
  description = "SSH hint for the kind host (Amazon Linux uses ec2-user)"
  value       = module.ec2.ssh_command
}

output "kind_host_ready" {
  description = "Wait for user-data (tools + git clone) before running bootstrap"
  value       = module.ec2.provisioning_note
}

output "project_dir_on_host" {
  description = "Cloned project path on the EC2 kind host"
  value       = "/home/ec2-user/postgresql-streaming-replication-k8s"
}
