# ── Load Balancer IP ─────────────────────────────────────────────────────────────
# This IP will be used by the Kubernetes LoadBalancer service
# configured in k8s/service.yaml
#
# In the Kapsule architecture, the Load Balancer is managed by Kubernetes
# through a Service of type LoadBalancer. We only reserve the IP here.

resource "scaleway_lb_ip" "main" {
  # Public IP for the load balancer
  # This IP is attached to the Kubernetes LoadBalancer service
}

# ── Load Balancer ────────────────────────────────────────────────────────────────
# Basic LB configuration - detailed routing handled by Kubernetes

resource "scaleway_lb" "main" {
  name = "onboarding-lb-${local.suffix}"
  type = "LB-S"

  ip_ids = [scaleway_lb_ip.main.id]

  # Attach to private network for backend communication
  private_network {
    private_network_id = scaleway_vpc_private_network.main.id
  }

  tags = ["onboarding", "production", "kapsule"]
}
