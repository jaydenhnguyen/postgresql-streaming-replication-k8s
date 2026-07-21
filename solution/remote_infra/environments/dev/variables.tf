variable "profile" {
  type    = string
  default = "default"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "postgre_stream_repl_k8s"
}

variable "publicKey_path" {
  type        = string
  description = "Path to your local SSH public key (.pub) used for the EC2 kind host"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for the kind host"
  default     = "t3.medium"
}
