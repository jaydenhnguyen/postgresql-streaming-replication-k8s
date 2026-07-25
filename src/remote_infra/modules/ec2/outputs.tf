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

output "provisioning_note" {
  description = "How to tell when Docker/kind/kubectl and the cloned repo are ready after apply"
  value       = "Wait 3-5 min after apply. On the host: cat ~/user-data-status.txt ; test -f /var/lib/cloud/instance/kind-host-ready && ls ~/postgresql-streaming-replication-k8s/src/bootstrap.sh. Logs: /var/log/user-data.log and /var/log/cloud-init-output.log. If docker permission denied, reconnect SSH."
}
