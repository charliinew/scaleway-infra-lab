# ── VPC ────────────────────────────────────────────────────────────────────────
resource "scaleway_vpc" "main" {
  name = "onboarding-vpc"
}

# ── Private Network ────────────────────────────────────────────────────────────
resource "scaleway_vpc_private_network" "main" {
  name   = "onboarding-pn"
  vpc_id = scaleway_vpc.main.id
}

# ── Public Gateway ─────────────────────────────────────────────────────────────
resource "scaleway_vpc_public_gateway_ip" "main" {}

resource "scaleway_vpc_public_gateway" "main" {
  name            = "onboarding-pgw"
  type            = "VPC-GW-S"
  ip_id           = scaleway_vpc_public_gateway_ip.main.id
  bastion_enabled = true
}

resource "scaleway_vpc_gateway_network" "main" {
  gateway_id         = scaleway_vpc_public_gateway.main.id
  private_network_id = scaleway_vpc_private_network.main.id
  enable_masquerade  = true

  ipam_config {
    push_default_route = true
  }
}
