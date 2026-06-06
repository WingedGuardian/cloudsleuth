output "accelerator_dns" {
  value = module.accelerator.dns_name
}

output "accelerator_ips" {
  value = module.accelerator.static_ips
}

output "primary_instance_id" {
  value = module.primary_compute.instance_id
}

output "secondary_instance_id" {
  value = module.secondary_compute.instance_id
}

output "detector_function_name" {
  value = module.monitoring.detector_function_name
}

output "sns_topic_arn" {
  value = module.monitoring.sns_topic_arn
}
