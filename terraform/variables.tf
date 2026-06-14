variable "primary_region" {
  type    = string
  default = "us-east-1"
}

variable "secondary_region" {
  type    = string
  default = "us-west-2"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "instance_type" {
  description = "t3.micro qualifies for free tier and provides baseline CPU metrics worth monitoring"
  type        = string
  default     = "t3.micro"
}

variable "github_org" {
  type    = string
  default = "WingedGuardian"
}

variable "github_repo" {
  type    = string
  default = "cloudsleuth"
}
