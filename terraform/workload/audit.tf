# Audit logging for the federation path.
#
# This is the point of the whole setup: proving after the fact which GitHub
# workflow run obtained credentials, and on whose behalf.
#
# Without this config the STS exchange - the one event carrying the repository,
# ref, environment, actor and workflow attributes - leaves no trace at all. The
# impersonation that follows it is logged by default, but records only the
# service account, not who caused it to be used.
#
# ADMIN_READ is the one that matters. STS emits its token exchange as an
# ADMIN_READ event, not DATA_READ: configuring only DATA_READ and DATA_WRITE
# yields an empty log, verified against a real workflow run that produced zero
# sts.googleapis.com entries. DATA_READ and DATA_WRITE are kept so no event
# class is silently dropped, but ADMIN_READ is what makes the exchange visible.
#
# Note this resource is authoritative for the service: it replaces any audit
# config already set on sts.googleapis.com.

resource "google_project_iam_audit_config" "sts" {
  project = var.project_id
  service = "sts.googleapis.com"

  # The token exchange itself.
  audit_log_config {
    log_type = "ADMIN_READ"
  }

  audit_log_config {
    log_type = "DATA_READ"
  }

  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

# There is deliberately no audit config for iamcredentials.googleapis.com.
# It rejects one:
#
#   Error 400: Service iamcredentials.googleapis.com does not exist or does
#   not support service level configuration of Google Cloud audit logging
#
# GenerateAccessToken is already written to the data_access log without any
# configuration, and that behaviour cannot be declared or pinned here. The
# audit trail therefore depends on a Google default for the impersonation half
# of the chain, and only the STS half above is under our control.
