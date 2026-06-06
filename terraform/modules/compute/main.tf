terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

variable "environment" {}
variable "vpc_id" {}
variable "vpc_cidr" {}
variable "subnet_id" {}
variable "instance_type" {}
variable "desired_state" {}
variable "app_port" {}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "app" {
  name_prefix = "cloudsleuth-app-"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # SSM agent needs outbound HTTPS
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "cloudsleuth-${var.environment}-app" }
}

resource "aws_iam_role" "instance" {
  name_prefix = "cloudsleuth-ec2-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# SSM managed instance + CloudWatch agent
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "app" {
  name_prefix = "cloudsleuth-"
  role        = aws_iam_role.instance.name
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    app_port = var.app_port
  }))

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  tags = {
    Name = "cloudsleuth-${var.environment}-${var.desired_state == "running" ? "primary" : "secondary"}"
    Role = var.desired_state == "running" ? "primary" : "secondary"
  }
}

# pilot light: costs pennies stopped — Lambda warms it on ELEVATED so it's already running when CRITICAL fires
# terraform-native instance state management
resource "aws_ec2_instance_state" "this" {
  instance_id = aws_instance.app.id
  state       = var.desired_state
}

output "instance_id" {
  value = aws_instance.app.id
}

output "public_ip" {
  value = aws_instance.app.public_ip
}

output "security_group_id" {
  value = aws_security_group.app.id
}
