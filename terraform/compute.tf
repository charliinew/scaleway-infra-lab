# ── SSH Key ────────────────────────────────────────────────────────────────────
resource "scaleway_account_ssh_key" "main" {
  name       = "onboarding-key"
  public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

# ── Placement Group (low latency entre les instances) ─────────────────────────
resource "scaleway_instance_placement_group" "main" {
  name        = "onboarding-pg"
  policy_type = "low_latency"
  policy_mode = "optional"
}

# ── Security Groups ────────────────────────────────────────────────────────────
resource "scaleway_instance_security_group" "image_processor" {
  name                    = "sg-image-processor"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  inbound_rule {
    action   = "accept"
    port     = 22
    protocol = "TCP"
  }

  inbound_rule {
    action   = "accept"
    port     = 9090
    protocol = "TCP"
  }
}

resource "scaleway_instance_security_group" "rest_api" {
  name                    = "sg-rest-api"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  inbound_rule {
    action   = "accept"
    port     = 22
    protocol = "TCP"
  }

  inbound_rule {
    action   = "accept"
    port     = 8080
    protocol = "TCP"
  }
}

# ── Instance image-processor ───────────────────────────────────────────────────
resource "scaleway_instance_server" "image_processor" {
  name               = "onboarding-image-processor"
  type               = var.instance_type
  image              = "ubuntu_jammy"
  security_group_id  = scaleway_instance_security_group.image_processor.id
  placement_group_id = scaleway_instance_placement_group.main.id

  root_volume {
    size_in_gb = 20
  }

  user_data = {
    "cloud-init" = templatefile("${path.module}/cloud-init/image-processor.yaml.tpl", {
      registry_namespace = var.registry_namespace
      secret_key         = var.secret_key
    })
  }

  depends_on = [scaleway_vpc_gateway_network.main]
}

# NIC attaché au réseau privé — le DHCP lui attribue une IP automatiquement
resource "scaleway_instance_private_nic" "image_processor" {
  server_id          = scaleway_instance_server.image_processor.id
  private_network_id = scaleway_vpc_private_network.main.id
}

# ── Instance rest-api ──────────────────────────────────────────────────────────
# Créée après le NIC image-processor pour connaître son IP privée
resource "scaleway_instance_server" "rest_api" {
  name               = "onboarding-rest-api"
  type               = var.instance_type
  image              = "ubuntu_jammy"
  security_group_id  = scaleway_instance_security_group.rest_api.id
  placement_group_id = scaleway_instance_placement_group.main.id

  root_volume {
    size_in_gb = 20
  }

  user_data = {
    "cloud-init" = templatefile("${path.module}/cloud-init/rest-api.yaml.tpl", {
      registry_namespace = var.registry_namespace
      secret_key         = var.secret_key
      access_key         = var.access_key
      project_id         = var.project_id
      image_processor_ip = local.image_processor_ipv4
    })
  }

  depends_on = [scaleway_rdb_instance.main]
}

resource "scaleway_instance_private_nic" "rest_api" {
  server_id          = scaleway_instance_server.rest_api.id
  private_network_id = scaleway_vpc_private_network.main.id
}
