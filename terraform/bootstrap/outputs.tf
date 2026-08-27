output "tfstate_bucket" {
  description = "Bucket name to configure as the `backend \"gcs\"` bucket in the root module."
  value       = google_storage_bucket.tfstate.name
}
