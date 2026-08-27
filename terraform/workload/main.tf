provider "google" {
  project = var.project_id
  region  = var.region
}

# The project is a bootstrap prerequisite rather than a managed resource, so a
# destroy of this module can never take the project with it. Creation steps are
# documented in terraform/README.md.
data "google_project" "this" {
  project_id = var.project_id
}

# APIs the publish pipeline depends on.
#
# cloudresourcemanager.googleapis.com is deliberately absent: the bootstrap
# module enables it, because the `data "google_project"` lookup above needs it
# before this module can even plan. Listing it here too would leave one API
# claimed by two states.
resource "google_project_service" "required" {
  for_each = toset([
    "iam.googleapis.com",            # service accounts and WIF pools
    "iamcredentials.googleapis.com", # short-lived token minting
    "sts.googleapis.com",            # WIF token exchange
    "chromewebstore.googleapis.com", # CWS v2 publishing API
    "logging.googleapis.com",        # STS audit trail
  ])

  project = var.project_id
  service = each.value

  # Disabling a service deletes everything that depends on it, and these are
  # shared project-wide. Leave them on when this module is destroyed.
  disable_on_destroy = false
}
