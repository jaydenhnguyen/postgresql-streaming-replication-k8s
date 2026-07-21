resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-ec2-sg"
  description = "Security group for the EC2 kind host"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-ec2-sg"
  }
}

resource "aws_security_group_rule" "ssh_ingress" {
  type              = "ingress"
  security_group_id = aws_security_group.ec2.id
  description       = "Allow SSH to the kind host"

  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "all_egress" {
  type              = "egress"
  security_group_id = aws_security_group.ec2.id
  description       = "Allow all outbound traffic (pull images, apt, etc.)"

  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}
