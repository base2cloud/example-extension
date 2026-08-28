variable "project_id" {
  description = "ID of the pre-existing GCP project that hosts the CWS publish infrastructure."
  type        = string
}

variable "region" {
  description = "Region for regional resources."
  type        = string
  default     = "australia-southeast1"
}

variable "cws_publisher_id" {
  description = "Chrome Web Store publisher ID, from Publisher > Settings in the dashboard."
  type        = string
}

variable "cws_extension_id" {
  description = "Chrome Web Store extension (item) ID."
  type        = string

  validation {
    condition     = can(regex("^[a-p]{32}$", var.cws_extension_id))
    error_message = "cws_extension_id must be 32 characters in the range a-p."
  }
}

variable "poller_schedule" {
  description = <<-EOT
    Cron schedule for the status poller, in UTC. This sets detection
    resolution: a change made and reverted between two polls is never
    observed, so it is a threat-model decision rather than a cost one.
  EOT
  type        = string
  default     = "*/5 * * * *"
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
