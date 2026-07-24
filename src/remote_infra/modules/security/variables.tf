variable "project_name" {
  type        = string
  description = "Name prefix used for resource tags and Name tags"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where the EC2 security group will be created"
}