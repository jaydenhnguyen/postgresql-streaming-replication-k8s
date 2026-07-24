module "network" {
  source = "../../modules/network"

  project_name = var.project_name
}

module "security" {
  source = "../../modules/security"

  project_name = var.project_name
  vpc_id       = module.network.vpc_id
}

module "key_pair" {
  source = "../../modules/key_pair"

  project_name   = var.project_name
  publicKey_path = var.publicKey_path
}

module "ec2" {
  source = "../../modules/ec2"

  project_name      = var.project_name
  subnet_id         = module.network.public_subnet_id
  security_group_id = module.security.ec2_sg_id
  key_name          = module.key_pair.key_name
  instance_type     = var.instance_type
}