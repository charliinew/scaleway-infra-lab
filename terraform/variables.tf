variable "access_key" {
  description = "Scaleway access key"
}

variable "secret_key" {
  description = "Scaleway secret key"
  sensitive   = true
}

variable "project_id" {
  description = "Scaleway project ID"
}

variable "registry_namespace" {
  description = "Container registry namespace name (already existing)"
}

variable "bucket_name" {
  description = "Object storage bucket name (already existing)"
}

variable "db_user" {
  description = "Database username"
  default     = "onboarding"
}

variable "db_password" {
  description = "Database password"
  sensitive   = true
}

variable "db_name" {
  description = "Database name"
  default     = "onboarding"
}

# ── Kapsule Configuration ──────────────────────────────────────────────────────

variable "kapsule_version" {
  description = "Kubernetes version for Kapsule cluster"
  default     = "1.34"
}

variable "kapsule_node_type" {
  description = "Node type for default Kapsule pool"
  default     = "DEV1-S"
}

variable "kapsule_pool_size" {
  description = "Initial number of nodes in default pool"
  default     = 2
}

variable "kapsule_pool_min_size" {
  description = "Minimum number of nodes in default pool"
  default     = 1
}

variable "kapsule_pool_max_size" {
  description = "Maximum number of nodes in default pool (auto-scaling)"
  default     = 5
}

variable "serverless_node_type" {
  description = "Node type for serverless pool"
  default     = "DEV1-M"
}

variable "serverless_pool_max_size" {
  description = "Maximum number of nodes in serverless pool"
  default     = 3
}

# ── AI / Generative API Configuration ─────────────────────────────────────────
# Uses Scaleway Generative APIs (OpenAI-compatible) with secret_key as auth token
# Base URL is constructed as: https://api.scaleway.ai/{project_id}/v1

variable "ai_model" {
  description = "Vision-capable model for alt-text generation"
  default     = "mistral-small-3.2-24b-instruct-2506"
}

# ── Feature Flags ──────────────────────────────────────────────────────────────

variable "create_serverless_namespace" {
  description = "Create a separate registry namespace for serverless containers"
  default     = false
}
