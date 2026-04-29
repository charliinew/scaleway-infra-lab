# ── Container Registry ─────────────────────────────────────────────────────────
# Le namespace existe déjà — on l'importe plutôt que de le recréer.
# Après terraform init, lance :
#   terraform import scaleway_registry_namespace.main fr-par/<namespace-id>
# L'ID se trouve avec : scw registry namespace list

resource "scaleway_registry_namespace" "main" {
  name       = "${var.registry_namespace}-${local.suffix}"
  is_public  = false
}
