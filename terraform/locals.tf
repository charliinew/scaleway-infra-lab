locals {
  # Extrait l'adresse IPv4 parmi les private_ips du NIC (exclut les IPv6 qui contiennent ":")
  image_processor_ipv4 = [
    for ip in scaleway_instance_private_nic.image_processor.private_ips : ip.address
    if !can(regex(":", ip.address))
  ][0]

  rest_api_ipv4 = [
    for ip in scaleway_instance_private_nic.rest_api.private_ips : ip.address
    if !can(regex(":", ip.address))
  ][0]
}
