# ── Serverless Containers Namespace ───────────────────────────────────────────
# https://registry.terraform.io/providers/scaleway/scaleway/latest/docs/resources/container_namespace

resource "scaleway_container_namespace" "main" {
  name        = "onboarding-converters-${local.suffix}"
  description = "Serverless containers for image processing and AI generation"

  depends_on = [scaleway_registry_namespace.main]
}

# ── Serverless Container: Image Converter ─────────────────────────────────────
# Gère la conversion d'images vers WebP, AVIF, JPEG, PNG
# https://registry.terraform.io/providers/scaleway/scaleway/latest/docs/resources/container

resource "scaleway_container" "image_converter" {
  name           = "image-converter"
  namespace_id   = scaleway_container_namespace.main.id
  registry_image = "rg.fr-par.scw.cloud/${scaleway_registry_namespace.main.name}/image-converter:latest"
  protocol       = "http1"
  port           = 8080

  # Scaling automatique
  min_scale = 0
  max_scale = 10

  # Ressources CPU/Mémoire
  cpu_limit    = 500
  memory_limit = 512

  # Environment variables
  environment_variables = {
    QWEN_BASE_URL = "https://api.scaleway.ai/${var.project_id}/v1"
    LOG_LEVEL     = "info"
  }

  secret_environment_variables = {
    QWEN_API_KEY = var.secret_key
  }

  depends_on = [scaleway_container_namespace.main]
}

# ── Serverless Container: AI Alt Generator ─────────────────────────────────────
# Génère automatiquement l'alt-text et le HTML accessible via Scaleway Generative APIs

resource "scaleway_container" "ai_alt_generator" {
  name           = "ai-alt-generator"
  namespace_id   = scaleway_container_namespace.main.id
  registry_image = "rg.fr-par.scw.cloud/${scaleway_registry_namespace.main.name}/ai-alt-generator:latest"
  protocol       = "http1"
  port           = 8080

  # Scaling automatique
  min_scale = 0
  max_scale = 5

  # Ressources
  cpu_limit    = 1000
  memory_limit = 1024

  # Environment variables
  environment_variables = {
    QWEN_MODEL        = var.ai_model
    QWEN_BASE_URL     = "https://api.scaleway.ai/${var.project_id}/v1"
    MAX_IMAGE_SIZE_MB = "10"
    LOG_LEVEL         = "info"
  }

  secret_environment_variables = {
    QWEN_API_KEY = var.secret_key
  }

  depends_on = [scaleway_container_namespace.main]
}
