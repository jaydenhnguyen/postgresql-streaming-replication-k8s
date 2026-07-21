output "key_name" {
  description = "Name of the AWS key pair (pass to EC2 key_name)"
  value       = aws_key_pair.this.key_name
}

output "key_pair_id" {
  description = "ID of the AWS key pair"
  value       = aws_key_pair.this.id
}

output "fingerprint" {
  description = "MD5 public key fingerprint as known by AWS"
  value       = aws_key_pair.this.fingerprint
}
