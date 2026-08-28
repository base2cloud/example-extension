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

# Export path: Cloud Logging -> Pub/Sub -> Sentinel.
#
# ADMIN_READ above makes STS write the exchange event, but says nothing about
# where it goes afterward - by default it sits in the project's _Default log
# bucket with standard retention and nothing outside GCP ever sees it. The
# poller's snapshot sink (see poller.tf) proves the listing changed; without
# this, there is no second stream for Sentinel to join against, so the
# detection this whole file exists for has no data to run on.
#
# Kept in its own topic and subscription rather than merged into the poller's
# cws-status-snapshots export: the payload shapes are unrelated - a Google
# audit log protoPayload versus our own jsonPayload schema - and Sentinel's GCP
# connector maps one topic to one table, so mixing them would land two
# incompatible schemas in a single table.

resource "google_pubsub_topic" "sts_audit_events" {
  project = var.project_id
  name    = "sts-audit-events"

  depends_on = [google_project_service.required]
}

resource "google_logging_project_sink" "sts_audit_events" {
  project     = var.project_id
  name        = "sts-audit-events"
  destination = "pubsub.googleapis.com/${google_pubsub_topic.sts_audit_events.id}"

  # Matches the ExchangeToken call specifically, not every sts.googleapis.com
  # entry, so an unrelated STS method added later does not silently join this
  # detection feed without a deliberate filter change.
  filter = join(" AND ", [
    "logName=\"projects/${var.project_id}/logs/cloudaudit.googleapis.com%2Fdata_access\"",
    "protoPayload.serviceName=\"sts.googleapis.com\"",
    "protoPayload.methodName=\"google.identity.sts.v1.SecurityTokenService.ExchangeToken\"",
  ])

  # Give the sink its own writer identity rather than the shared, broadly
  # privileged default log writer.
  unique_writer_identity = true

  depends_on = [google_project_iam_audit_config.sts]
}

resource "google_pubsub_topic_iam_member" "sts_sink_writer" {
  project = var.project_id
  topic   = google_pubsub_topic.sts_audit_events.name
  role    = "roles/pubsub.publisher"
  member  = google_logging_project_sink.sts_audit_events.writer_identity
}

resource "google_pubsub_subscription" "sts_audit_events_sentinel" {
  project = var.project_id
  name    = "sts-audit-events-sentinel"
  topic   = google_pubsub_topic.sts_audit_events.id

  # Matches the poller's export subscription: long enough that a Sentinel
  # connector outage over a weekend does not lose events and leave an
  # unexplained gap in the detection timeline.
  message_retention_duration = "604800s" # 7 days
  ack_deadline_seconds       = 60

  expiration_policy {
    # Never expire. The default deletes a subscription after 31 days without a
    # consumer, which would quietly dismantle the export path.
    ttl = ""
  }
}
