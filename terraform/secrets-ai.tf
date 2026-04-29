# ── Secret Manager: AI & Qwen API Credentials ──────────────────────────────────
# Stocke les clés API sensibles pour les services d'IA
# https://registry.terraform.io/providers/scaleway/scaleway/latest/docs/resources/secret

# Secret pour Qwen API (vision et génération de texte)
resource "scaleway_secret" "qwen_api_key" {
  name        = "onboarding-qwen-api-key-${local.suffix}"
  description = "Qwen API key for AI image analysis and alt-text generation"
  path        = "/onboarding/ai"
  tags        = ["onboarding", "ai", "qwen", "production"]
}

# Version du secret avec la valeur actualle
# La valeur est fournie via la variable terraform.tfvars
resource "scaleway_secret_version" "qwen_api_key" {
  secret_id = scaleway_secret.qwen_api_key.id

  data = jsonencode({
    QWEN_API_KEY  = var.secret_key
    QWEN_BASE_URL = "https://api.scaleway.ai/${var.project_id}/v1"
    QWEN_MODEL    = var.ai_model
  })
}

# ── Secret Manager: Registry Credentials (optionnel) ───────────────────────────
# Credentials pour le registry privé (si nécessaire pour les Serverless Containers)

resource "scaleway_secret" "registry_credentials" {
  name        = "onboarding-registry-credentials-${local.suffix}"
  description = "Docker registry credentials for pulling serverless container images"
  path        = "/onboarding/registry"
  tags        = ["onboarding", "registry", "docker"]
}

resource "scaleway_secret_version" "registry_credentials" {
  secret_id = scaleway_secret.registry_credentials.id

  data = jsonencode({
    REGISTRY_URL       = "rg.fr-par.scw.cloud"
    REGISTRY_NAMESPACE = var.registry_namespace
    REGISTRY_USERNAME  = "nologin"
    REGISTRY_PASSWORD  = var.secret_key
  })
}

# ── Secret Manager: Database & S3 Credentials ───────────────────────────────────
# Note: These secrets are created by terraform/secrets.tf
# They are accessed at runtime by the application via Secret Manager API

# ── Secret Manager: Image Processor Token (service-to-service auth) ────────────
# Token pour l'authentification entre rest-api et image-converter

resource "scaleway_secret" "image_processor_token" {
  name        = "onboarding-image-processor-token-${local.suffix}"
  description = "Auth token for service-to-service communication with image converter"
  path        = "/onboarding/services"
  tags        = ["onboarding", "services", "auth"]
}

resource "random_password" "image_processor_token" {
  length  = 32
  special = false
  lifecycle {
    ignore_changes = all
  }
}

resource "scaleway_secret_version" "image_processor_token" {
  secret_id = scaleway_secret.image_processor_token.id

  data = jsonencode({
    TOKEN = "Bearer ${random_password.image_processor_token.result}"
  })
}

# ── Secret Manager: AI Configuration ───────────────────────────────────────────
# Configuration avancée pour les services d'IA

resource "scaleway_secret" "ai_config" {
  name        = "onboarding-ai-config-${local.suffix}"
  description = "AI service configuration (model params, rate limits, etc.)"
  path        = "/onboarding/ai/config"
  tags        = ["onboarding", "ai", "config"]
}

resource "scaleway_secret_version" "ai_config" {
  secret_id = scaleway_secret.ai_config.id

  data = jsonencode({
    VISION_MODEL        = "qwen-vl-max"
    TEXT_MODEL          = "qwen-max"
    API_TIMEOUT_SECONDS = "30"
    MAX_IMAGE_SIZE_MB   = "10"
    MAX_ALT_TEXT_LENGTH = "250"
    RATE_LIMIT_PER_MIN  = "60"
    AI_CACHE_ENABLED    = "true"
    AI_CACHE_TTL_HOURS  = "24"
  })
}
