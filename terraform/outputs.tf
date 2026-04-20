output "load_balancer_ip" {
  description = "IP publique du load balancer — point d'entrée de l'application"
  value       = scaleway_lb_ip.main.ip_address
}

output "gateway_ip" {
  description = "IP publique du public gateway — pour accès SSH bastion"
  value       = scaleway_vpc_public_gateway_ip.main.address
}

output "image_processor_private_ip" {
  description = "IP privée IPv4 de l'instance image-processor"
  value       = local.image_processor_ipv4
}

output "rest_api_private_ip" {
  description = "IP privée IPv4 de l'instance rest-api"
  value       = local.rest_api_ipv4
}

output "ssh_bastion_command_image_processor" {
  description = "Commande SSH pour accéder à l'instance image-processor via le bastion"
  value       = "ssh -J bastion@${scaleway_vpc_public_gateway_ip.main.address}:61000 root@${local.image_processor_ipv4}"
}

output "ssh_bastion_command_rest_api" {
  description = "Commande SSH pour accéder à l'instance rest-api via le bastion"
  value       = "ssh -J bastion@${scaleway_vpc_public_gateway_ip.main.address}:61000 root@${local.rest_api_ipv4}"
}

output "test_upload_command" {
  description = "Commande curl pour tester l'upload d'une image"
  value       = "curl -F 'file=@logo.png' http://${scaleway_lb_ip.main.ip_address}/upload"
}
