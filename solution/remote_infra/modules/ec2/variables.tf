variable "project_name" {
  type        = string
  description = "Name prefix used for resource tags and Name tags"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type (kind needs enough CPU/RAM for 1 control-plane + 2 workers)"
  default     = "t3.medium"
}

variable "subnet_id" {
  type        = string
  description = "Public subnet ID for the EC2 / kind host"
}

variable "security_group_id" {
  type        = string
  description = "Security group ID for the EC2 / kind host"
}

variable "key_name" {
  type        = string
  description = "AWS key pair name used for SSH access"
}

variable "ami_id" {
  type        = string
  description = "Optional AMI ID. Empty string = latest Amazon Linux 2023 in the region."
  default     = "ami-02dfbd4ff395f2a1b"
}

variable "root_volume_size" {
  type        = number
  description = "Root EBS volume size in GiB (Docker/kind images need headroom)"
  default     = 40
}

variable "root_volume_type" {
  type        = string
  description = "Root EBS volume type"
  default     = "gp3"
}
