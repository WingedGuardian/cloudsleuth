terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "cloudsleuth-tfstate"
    key            = "terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "cloudsleuth-tflock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.primary_region

  default_tags {
    tags = {
      Project     = "cloudsleuth"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

provider "aws" {
  alias  = "secondary"
  region = var.secondary_region

  default_tags {
    tags = {
      Project     = "cloudsleuth"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# --- Primary region (active) ---

module "primary_network" {
  source    = "./modules/networking"
  providers = { aws = aws }

  environment = var.environment
  vpc_cidr    = "10.0.0.0/16"
  region_tag  = "primary"
}

module "primary_compute" {
  source    = "./modules/compute"
  providers = { aws = aws }

  environment   = var.environment
  vpc_id        = module.primary_network.vpc_id
  vpc_cidr      = "10.0.0.0/16"
  subnet_id     = module.primary_network.public_subnet_id
  instance_type = var.instance_type
  desired_state = "running"
  app_port      = 8000
}

# --- Secondary region (pilot light — stopped until failover) ---

module "secondary_network" {
  source    = "./modules/networking"
  providers = { aws = aws.secondary }

  environment = var.environment
  vpc_cidr    = "10.1.0.0/16"
  region_tag  = "secondary"
}

module "secondary_compute" {
  source    = "./modules/compute"
  providers = { aws = aws.secondary }

  environment   = var.environment
  vpc_id        = module.secondary_network.vpc_id
  vpc_cidr      = "10.1.0.0/16"
  subnet_id     = module.secondary_network.public_subnet_id
  instance_type = var.instance_type
  desired_state = "stopped"
  app_port      = 8000
}

# --- Global / cross-region ---

module "iam" {
  source = "./modules/iam"

  environment = var.environment
  github_org  = var.github_org
  github_repo = var.github_repo
}

module "accelerator" {
  source = "./modules/accelerator"

  environment           = var.environment
  primary_instance_id   = module.primary_compute.instance_id
  primary_region        = var.primary_region
  secondary_instance_id = module.secondary_compute.instance_id
  secondary_region      = var.secondary_region
  app_port              = 8000
}

module "monitoring" {
  source = "./modules/monitoring"

  environment                  = var.environment
  primary_instance_id          = module.primary_compute.instance_id
  primary_public_ip            = module.primary_compute.public_ip
  primary_region               = var.primary_region
  secondary_instance_id        = module.secondary_compute.instance_id
  secondary_region             = var.secondary_region
  ssm_role_arn                 = module.iam.ssm_automation_role_arn
  primary_endpoint_group_arn   = module.accelerator.primary_endpoint_group_arn
  secondary_endpoint_group_arn = module.accelerator.secondary_endpoint_group_arn
  app_port                     = 8000
}
