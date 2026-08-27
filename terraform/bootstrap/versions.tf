terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.46"
    }
  }

  # Deliberately no backend block: this module runs on local state.
  # See README.md for why.
}
