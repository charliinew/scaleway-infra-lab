# ── Kapsule Cluster (Managed Kubernetes) ──────────────────────────────────────
# https://registry.terraform.io/providers/scaleway/scaleway/latest/docs/resources/k8s_cluster

resource "scaleway_k8s_cluster" "main" {
  name                        = "onboarding-kapsule-${local.suffix}"
  version                     = "1.34" # Minor version required with auto_upgrade
  description                 = "Kapsule cluster for image conversion service"
  delete_additional_resources = true

  # CNI pour le réseau pod-to-pod
  cni = "calico"

  # Activer l'auto-upgrade (maintenance automatique)
  auto_upgrade {
    enable                        = true
    maintenance_window_day        = "sunday"
    maintenance_window_start_hour = 3
  }

  # Réseau privé pour communication interne
  private_network_id = scaleway_vpc_private_network.main.id

  # Tags pour l'organisation
  tags = ["onboarding", "production", "image-converter"]

  depends_on = [scaleway_vpc_gateway_network.main]
}

# ── Node Pool (Worker Nodes) ───────────────────────────────────────────────────
# https://registry.terraform.io/providers/scaleway/scaleway/latest/docs/resources/k8s_pool

resource "scaleway_k8s_pool" "default" {
  name       = "default-pool"
  cluster_id = scaleway_k8s_cluster.main.id

  # Type d'instance : PRO2-XS pour prod (DEV1-S not available in fr-par)
  node_type = "PRO2-XS"
  size      = 2 # Nombre initial de nodes
  min_size  = 1 # Minimum pour le cluster
  max_size  = 5 # Maximum pour l'auto-scaling

  # Configuration du root volume (PRO2-XS supports sbs_5k)
  root_volume_size_in_gb = 20
  root_volume_type       = "sbs_5k" # Block Storage 5K IOPS

  # Tags
  tags = ["onboarding", "default-pool", "image-converter"]

  # Attendre que le cluster soit prêt
  depends_on = [scaleway_k8s_cluster.main]
}

# ── Kubernetes ConfigMap - Cluster Info ───────────────────────────────────────
# Stocke les infos du cluster pour les autres ressources Terraform

data "scaleway_k8s_cluster" "main" {
  cluster_id = scaleway_k8s_cluster.main.id
  depends_on = [scaleway_k8s_cluster.main]
}

# ── Container Registry pour Kapsule ───────────────────────────────────────────
# Permet au cluster de pull les images depuis le registry privé

resource "scaleway_k8s_pool" "serverless" {
  name       = "serverless-pool"
  cluster_id = scaleway_k8s_cluster.main.id

  # Pool dédié aux workloads serverless (scale to zero possible)
  node_type = "DEV1-M" # Plus de RAM pour les conversions
  size      = 1
  min_size  = 0 # Scale to zero quand inactif
  max_size  = 3

  root_volume_size_in_gb = 40
  root_volume_type       = "sbs_5k" # Block Storage 5K IOPS

  # Tags
  tags = ["onboarding", "serverless-pool", "image-converter"]

  depends_on = [scaleway_k8s_cluster.main]
}
