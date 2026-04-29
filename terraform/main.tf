terraform {
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.73"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  required_version = ">= 1.0"
}

provider "scaleway" {
  # Configuration is loaded from:
  # - Environment variables (SCW_ACCESS_KEY, SCW_SECRET_KEY, etc.)
  # - Scaleway config file (~/.config/scw/config.yaml)
  # - terraform.tfvars variables
}
