terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.46"
    }
  }

  # Bucket is created by terraform/bootstrap. Backend config cannot use
  # variables, so the name is spelled out here.
  backend "gcs" {
    bucket = "chrome-extension-506804-tfstate"
    prefix = "cws-publish"
  }
}
