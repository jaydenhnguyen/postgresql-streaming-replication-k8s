variable "project_name" {
  type        = string
  description = "Name prefix used for resource tags and Name tags"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type        = string
  description = "CIDR block for the public subnet (EC2 / kind host)"
  default     = "10.0.1.0/24"
}

variable "availability_zone" {
  type        = string
  description = "AZ for the public subnet. Empty string = first available AZ in the region."
  default     = ""
}
