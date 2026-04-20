# ── Secret Manager ─────────────────────────────────────────────────────────────
# ACCESS_KEY et SECRET_KEY restent en env vars (nécessaires pour s'authentifier
# à Secret Manager). Les autres credentials sensibles sont ici.

resource "scaleway_secret" "database_url" {
  name = "onboarding-database-url"
}

resource "scaleway_secret_version" "database_url" {
  secret_id = scaleway_secret.database_url.id
  data      = "postgresql://${var.db_user}:${var.db_password}@${scaleway_rdb_instance.main.private_network[0].ip}:${scaleway_rdb_instance.main.private_network[0].port}/${var.db_name}"
}

resource "scaleway_secret" "bucket_name" {
  name = "onboarding-bucket-name"
}

resource "scaleway_secret_version" "bucket_name" {
  secret_id = scaleway_secret.bucket_name.id
  data      = var.bucket_name
}
