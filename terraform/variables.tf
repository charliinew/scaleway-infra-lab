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

variable "ssh_public_key_path" {
  description = "Path to SSH public key file"
  default     = "~/.ssh/id_ed25519.pub"
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

variable "instance_type" {
  description = "Scaleway instance type"
  default     = "DEV1-S"
}
