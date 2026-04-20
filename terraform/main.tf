terraform {
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.49"
    }
  }
  required_version = ">= 1.0"
}

provider "scaleway" {}
