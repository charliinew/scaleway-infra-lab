# ── Object Storage ─────────────────────────────────────────────────────────────
# Le bucket existe déjà — on l'importe plutôt que de le recréer.
# Après terraform init, lance :
#   terraform import scaleway_object_bucket.main fr-par/<bucket-name>

resource "scaleway_object_bucket" "main" {
  name          = var.bucket_name
  region        = "fr-par"
  force_destroy = true
}
