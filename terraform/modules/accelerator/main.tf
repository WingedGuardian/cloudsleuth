variable "environment" {
  type = string
}
variable "primary_instance_id" {
  type = string
}
variable "primary_region" {
  type = string
}
variable "secondary_instance_id" {
  type = string
}
variable "secondary_region" {
  type = string
}
variable "app_port" {
  type = number
}

resource "aws_globalaccelerator_accelerator" "this" {
  name            = "cloudsleuth-${var.environment}"
  ip_address_type = "IPV4"
  enabled         = true
}

resource "aws_globalaccelerator_listener" "http" {
  accelerator_arn = aws_globalaccelerator_accelerator.this.id
  protocol        = "TCP"

  port_range {
    from_port = 80
    to_port   = 80
  }
}

resource "aws_globalaccelerator_endpoint_group" "primary" {
  listener_arn          = aws_globalaccelerator_listener.http.id
  endpoint_group_region = var.primary_region

  # Route 53 failover takes 60-120s for TTL drain; Global Accelerator shifts in ~30s — worth the extra cost for a failover product
  # starts at 100 — SSM automation shifts to 0 during failover
  traffic_dial_percentage = 100

  endpoint_configuration {
    endpoint_id                    = var.primary_instance_id
    weight                         = 100
    client_ip_preservation_enabled = true
  }

  health_check_port             = var.app_port
  health_check_protocol         = "HTTP"
  health_check_path             = "/health"
  health_check_interval_seconds = 10
  threshold_count               = 3

  port_override {
    endpoint_port = var.app_port
    listener_port = 80
  }
}

resource "aws_globalaccelerator_endpoint_group" "secondary" {
  listener_arn          = aws_globalaccelerator_listener.http.id
  endpoint_group_region = var.secondary_region

  # starts at 0--pilot light is dark until failover activates it
  traffic_dial_percentage = 0

  endpoint_configuration {
    endpoint_id                    = var.secondary_instance_id
    weight                         = 100
    client_ip_preservation_enabled = true
  }

  health_check_port             = var.app_port
  health_check_protocol         = "HTTP"
  health_check_path             = "/health"
  health_check_interval_seconds = 10
  threshold_count               = 3

  port_override {
    endpoint_port = var.app_port
    listener_port = 80
  }
}

output "dns_name" {
  value = aws_globalaccelerator_accelerator.this.dns_name
}

output "static_ips" {
  value = aws_globalaccelerator_accelerator.this.ip_sets[*].ip_addresses
}

output "primary_endpoint_group_arn" {
  value = aws_globalaccelerator_endpoint_group.primary.arn
}

output "secondary_endpoint_group_arn" {
  value = aws_globalaccelerator_endpoint_group.secondary.arn
}
