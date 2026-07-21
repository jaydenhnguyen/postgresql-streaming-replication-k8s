variable "project_name" {
  type        = string
  description = "Name prefix used for resource tags and the AWS key pair name"
}

variable "publicKey_path" {
  type        = string
  description = "Path to the local SSH public key file on your machine"
}

variable "key_name" {
  type        = string
  description = "Name of the key pair in AWS. Defaults to <project_name>-key."
  default     = ""
}
