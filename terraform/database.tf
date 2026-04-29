# ── Managed PostgreSQL ─────────────────────────────────────────────────────────
resource "scaleway_rdb_instance" "main" {
  name           = "onboarding-db-${local.suffix}"
  node_type      = "DB-DEV-S"
  engine         = "PostgreSQL-15"
  is_ha_cluster  = false
  disable_backup = true
  user_name      = var.db_user
  password       = var.db_password

  # Attaché au réseau privé uniquement (pas d'endpoint public)
  private_network {
    pn_id       = scaleway_vpc_private_network.main.id
    enable_ipam = true
  }

  depends_on = [scaleway_vpc_gateway_network.main]
}

resource "scaleway_rdb_database" "main" {
  instance_id = scaleway_rdb_instance.main.id
  name        = var.db_name
}

resource "scaleway_rdb_privilege" "main" {
  instance_id   = scaleway_rdb_instance.main.id
  user_name     = var.db_user
  database_name = scaleway_rdb_database.main.name
  permission    = "all"
}
