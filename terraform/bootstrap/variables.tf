variable "project_id" {
  description = "ID of the pre-existing GCP project that hosts the CWS publish infrastructure."
  type        = string
}

variable "region" {
  description = "Region for regional resources, including the Terraform state bucket."
  type        = string
  default     = "australia-southeast1"
}
