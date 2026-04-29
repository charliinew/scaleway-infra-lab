# ── Load Balancer Output ─────────────────────────────────────────────────────────
# Public IP for accessing the application

output "load_balancer_ip" {
  description = "Public IP address of the Load Balancer - main entry point"
  value       = scaleway_lb_ip.main.ip_address
}

output "load_balancer_id" {
  description = "ID of the Load Balancer - used for configuration"
  value       = scaleway_lb.main.id
}

# ── Gateway Output ───────────────────────────────────────────────────────────────
# Bastion host IP for SSH access

output "gateway_ip" {
  description = "Public IP of the gateway - used for SSH bastion access"
  value       = scaleway_vpc_public_gateway_ip.main.address
}

# ── Kapsule Cluster Outputs ──────────────────────────────────────────────────────
# Kubernetes cluster information

output "kapsule_cluster_id" {
  description = "ID of the Kapsule Kubernetes cluster"
  value       = scaleway_k8s_cluster.main.id
}

output "kapsule_kubeconfig_command" {
  description = "Command to retrieve kubeconfig for cluster access"
  value       = "scw k8s cluster get ${scaleway_k8s_cluster.main.id} --region fr-par"
}

output "kapsule_cluster_version" {
  description = "Kubernetes version running on the cluster"
  value       = scaleway_k8s_cluster.main.version
}

output "kapsule_default_pool_size" {
  description = "Number of nodes in the default pool"
  value       = scaleway_k8s_pool.default.size
}

output "kapsule_serverless_pool_size" {
  description = "Number of nodes in the serverless pool"
  value       = scaleway_k8s_pool.serverless.size
}

# ── Serverless Containers Outputs ────────────────────────────────────────────────
# Serverless Container services

output "serverless_namespace_id" {
  description = "ID of the Serverless Containers namespace"
  value       = scaleway_container_namespace.main.id
}

output "serverless_namespace_endpoint" {
  description = "Registry endpoint for the Serverless namespace"
  value       = scaleway_container_namespace.main.registry_endpoint
}

output "image_converter_container_id" {
  description = "ID of the image converter container"
  value       = scaleway_container.image_converter.id
}

output "image_converter_url" {
  description = "Public URL of the image converter service"
  value       = "https://${scaleway_container.image_converter.domain_name}"
}

output "ai_alt_generator_container_id" {
  description = "ID of the AI alt-generator container"
  value       = scaleway_container.ai_alt_generator.id
}

output "ai_alt_generator_url" {
  description = "Public URL of the AI alt-generator service"
  value       = "https://${scaleway_container.ai_alt_generator.domain_name}"
}

# ── Database Outputs ─────────────────────────────────────────────────────────────
# Managed PostgreSQL instance

output "database_id" {
  description = "ID of the managed PostgreSQL instance"
  value       = scaleway_rdb_instance.main.id
}

output "database_name" {
  description = "Name of the database"
  value       = scaleway_rdb_database.main.name
}

output "database_connection_string" {
  description = "PostgreSQL connection string (sensitive)"
  sensitive   = true
  value       = "postgresql://${var.db_user}:${var.db_password}@${scaleway_rdb_instance.main.private_network[0].ip}:${scaleway_rdb_instance.main.private_network[0].port}/${var.db_name}"
}

# ── Registry Outputs ─────────────────────────────────────────────────────────────

output "registry_namespace_name" {
  description = "Actual name of the container registry namespace (includes random suffix)"
  value       = scaleway_registry_namespace.main.name
}

# ── Object Storage Outputs ───────────────────────────────────────────────────────
# S3-compatible bucket

output "bucket_name" {
  description = "Name of the S3 bucket"
  value       = scaleway_object_bucket.main.name
}

output "bucket_endpoint" {
  description = "S3 bucket endpoint URL"
  value       = "https://${scaleway_object_bucket.main.name}.s3.fr-par.scw.cloud"
}

# ── Test Commands ────────────────────────────────────────────────────────────────
# Useful commands for testing the deployment

output "test_health_command" {
  description = "Command to test the health endpoint"
  value       = "curl http://${scaleway_lb_ip.main.ip_address}/health"
}

output "test_upload_command" {
  description = "Command to test image upload"
  value       = "curl -F 'file=@logo.png' http://${scaleway_lb_ip.main.ip_address}/upload"
}

output "test_converter_command" {
  description = "Command to test the image converter directly"
  value       = "curl -F 'file=@logo.png' -F 'format=webp' https://<container-id>.k8s-function.fr-par.scw.cloud/convert"
}

output "test_ai_generator_command" {
  description = "Command to test the AI alt-generator"
  value       = "curl -F 'file=@logo.png' https://<container-id>.k8s-function.fr-par.scw.cloud/generate-alt"
}

output "test_upload_with_ai_command" {
  description = "Command to test upload with AI alt-text generation"
  value       = "curl -F 'file=@logo.png' -F 'format=webp' -F 'generate_alt=true' http://${scaleway_lb_ip.main.ip_address}/upload"
}

# ── Deployment Summary ───────────────────────────────────────────────────────────
# Quick reference for accessing the deployment

output "deployment_summary" {
  description = "Summary of the deployment with key URLs and commands"
  value       = <<-EOT
    ╔═══════════════════════════════════════════════════════════╗
    ║          imgflow - Deployment Complete!                   ║
    ╚═══════════════════════════════════════════════════════════╝

    Load Balancer IP: ${scaleway_lb_ip.main.ip_address}
    Health Check:     http://${scaleway_lb_ip.main.ip_address}/health
    Test Upload:      curl -F 'file=@logo.png' http://${scaleway_lb_ip.main.ip_address}/upload

    Kubernetes Cluster: ${scaleway_k8s_cluster.main.id}
    Kubeconfig:         scw k8s cluster get ${scaleway_k8s_cluster.main.id} --region fr-par

    Image Converter:    https://${scaleway_container.image_converter.domain_name}
    AI Alt-Generator:   https://${scaleway_container.ai_alt_generator.domain_name}

    Database:           ${scaleway_rdb_database.main.name} on ${scaleway_rdb_instance.main.name}
    S3 Bucket:          https://${scaleway_object_bucket.main.name}.s3.fr-par.scw.cloud

    Next steps:
      1. Configure kubectl: scw k8s cluster get ${scaleway_k8s_cluster.main.id} --region fr-par
      2. Apply Kubernetes manifests: kubectl apply -f k8s/
      3. Test the deployment: make test
    EOT
}
