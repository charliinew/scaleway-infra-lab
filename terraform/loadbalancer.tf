# ── Load Balancer ──────────────────────────────────────────────────────────────
resource "scaleway_lb_ip" "main" {}

resource "scaleway_lb" "main" {
  name    = "onboarding-lb"
  ip_ids  = [scaleway_lb_ip.main.id]
  type    = "LB-S"

  private_network {
    private_network_id = scaleway_vpc_private_network.main.id
  }
}

resource "scaleway_lb_backend" "rest_api" {
  lb_id            = scaleway_lb.main.id
  name             = "backend-rest-api"
  forward_protocol = "http"
  forward_port     = 8080

  server_ips = [local.rest_api_ipv4]

  health_check_http {
    uri = "/health"
  }
}

resource "scaleway_lb_frontend" "rest_api" {
  lb_id        = scaleway_lb.main.id
  backend_id   = scaleway_lb_backend.rest_api.id
  name         = "frontend-http"
  inbound_port = 80
}
