provider "google" {
  project = var.project_id
  region  = var.region
}

# The root module reads project metadata through a data source, which goes via
# the Cloud Resource Manager API. Enable it here so `terraform init`/`plan` in
# the root module works on a freshly created project.
resource "google_project_service" "cloudresourcemanager" {
  project = var.project_id
  service = "cloudresourcemanager.googleapis.com"

  # Disabling a service deletes the resources that depend on it. A destroy of
  # this module should remove the bucket, not cascade into the whole project.
  disable_on_destroy = false
}

resource "google_storage_bucket" "tfstate" {
  name     = "${var.project_id}-tfstate"
  project  = var.project_id
  location = var.region

  # Every apply is recoverable: a corrupt or truncated state can be rolled back
  # to any previous generation.
  versioning {
    enabled = true
  }

  # IAM only, no per-object ACLs, and no path to making state world-readable.
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Refuse to delete a bucket that still holds state files.
  force_destroy = false

  # Keep history bounded without losing the recent rollback window.
  lifecycle_rule {
    condition {
      num_newer_versions = 20
    }
    action {
      type = "Delete"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}
