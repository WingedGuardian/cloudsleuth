variable "primary_region" {
  default = "us-east-1"
}

variable "secondary_region" {
  default = "us-west-2"
}

variable "environment" {
  default = "dev"
}

variable "instance_type" {
  description = "t3.micro qualifies for free tier and provides baseline CPU metrics worth monitoring"
  default     = "t3.micro"
}

variable "github_org" {
  default = "WingedGuardian"
}

variable "github_repo" {
  default = "cloudsleuth"
}
