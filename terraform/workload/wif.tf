locals {
  # GitHub's OIDC issuer. Tokens presented to STS are verified against this
  # issuer's published JWKS.
  github_issuer = "https://token.actions.githubusercontent.com"
}

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github-actions-pool"
  display_name              = "GitHub Actions"
  description               = "Federated identities for GitHub Actions in ${var.github_repository}."

  depends_on = [google_project_service.required]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC"

  # Only claims mapped here can be referenced by IAM principalSets or show up
  # as attributes in the STS audit log. actor and workflow are mapped purely
  # for the audit trail: they answer "who triggered this publish, from which
  # workflow" when reviewing the log after the fact.
  attribute_mapping = {
    "google.subject"        = "assertion.sub"
    "attribute.repository"  = "assertion.repository"
    "attribute.ref"         = "assertion.ref"
    "attribute.environment" = "assertion.environment"
    "attribute.actor"       = "assertion.actor"
    "attribute.workflow"    = "assertion.workflow"
  }

  # The security boundary. Every clause must hold or the token exchange is
  # refused before any Google credential exists:
  #
  #   repository  - no other repo, and no fork of this one, can use the provider
  #   ref         - only the protected branch; a feature branch cannot publish
  #   environment - forces the job through a GitHub Environment, which is where
  #                 the required-reviewer approval gate actually lives
  #
  # ref and environment are independent claims, so requiring both is not
  # redundant: ref pins *what code* runs, environment pins *who approved it*.
  #
  # A token with no environment claim (a job that omits `environment:`) fails
  # this condition rather than silently skipping review. It fails closed.
  attribute_condition = join(" && ", [
    "assertion.repository == ${jsonencode(var.github_repository)}",
    "assertion.ref == ${jsonencode("refs/heads/${var.github_branch}")}",
    "assertion.environment == ${jsonencode(var.github_environment)}",
  ])

  oidc {
    issuer_uri = local.github_issuer
  }
}

resource "google_service_account" "publisher" {
  project      = var.project_id
  account_id   = "cws-publisher"
  display_name = "Chrome Web Store publisher"
  description  = "Impersonated by GitHub Actions via WIF. Has no keys by design."

  depends_on = [google_project_service.required]
}

# Lets the federated GitHub identity impersonate the publisher SA.
#
# This is a second, independent gate. The provider's attribute_condition
# already pins branch and environment; scoping the principalSet to the
# repository attribute means that even if that condition were loosened later,
# only principals carrying this repository claim can reach the account.
#
# Deliberately NOT a service account key: no long-lived credential is created,
# so there is nothing to leak, rotate, or find in a GitHub secret.
resource "google_service_account_iam_member" "github_impersonation" {
  service_account_id = google_service_account.publisher.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}
