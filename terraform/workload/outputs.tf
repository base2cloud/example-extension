output "project_id" {
  description = "Project hosting the CWS publish infrastructure."
  value       = data.google_project.this.project_id
}

# Needed to build the workload identity pool audience that GitHub Actions
# presents during the STS token exchange.
output "project_number" {
  description = "Numeric project ID."
  value       = data.google_project.this.number
}

output "enabled_services" {
  description = "APIs this module keeps enabled on the project."
  value       = sort([for s in google_project_service.required : s.service])
}

output "wif_provider" {
  description = "Full provider resource name; set as the WIF_PROVIDER repo variable."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "publisher_service_account_email" {
  description = "SA impersonated by the pipeline; set as the WIF_SA_EMAIL repo variable."
  value       = google_service_account.publisher.email
}

output "poller_image" {
  description = "Image reference the Cloud Run Job pulls; the build workflow must push here."
  value       = local.poller_image
}

output "image_publisher_service_account_email" {
  description = "SA the image build workflow impersonates; set as IMAGE_PUBLISHER_SA_EMAIL."
  value       = google_service_account.image_publisher.email
}

output "attribute_condition" {
  description = "CEL expression gating the token exchange, surfaced for review."
  value       = google_iam_workload_identity_pool_provider.github.attribute_condition
}
