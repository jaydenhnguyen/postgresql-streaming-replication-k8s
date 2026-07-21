locals {
  key_name = var.key_name != "" ? var.key_name : "${var.project_name}-key"
}

resource "aws_key_pair" "this" {
  key_name   = local.key_name
  public_key = file(pathexpand(var.publicKey_path))

  tags = {
    Name = local.key_name
  }
}
