variable "project_id" {
  description = "ID of the pre-existing GCP project that hosts the CWS publish infrastructure."
  type        = string
}

variable "region" {
  description = "Region for regional resources."
  type        = string
  default     = "australia-southeast1"
}

variable "github_repository" {
  description = "Repository allowed to federate into this project, as owner/repo."
  type        = string

  validation {
    condition     = can(regex("^[^/[:space:]]+/[^/[:space:]]+$", var.github_repository))
    error_message = "github_repository must be in owner/repo form, e.g. base2cloud/example-extension."
  }
}

variable "github_branch" {
  description = "Only workflow runs on this branch may mint credentials."
  type        = string
  default     = "main"
}

variable "github_environment" {
  description = <<-EOT
    GitHub Environment the publishing job must declare. This must exist in the
    repository settings, and only carries security weight if it is configured
    with required reviewers and limited to the protected branch.
  EOT
  type        = string
  default     = "prd"
}
