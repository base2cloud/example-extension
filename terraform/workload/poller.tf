# CWS status poller: a Cloud Run Job on a schedule that snapshots the store
# listing into Cloud Logging, exported to Pub/Sub for Sentinel.
#
# The STS audit log proves a given publish went through the pipeline. It cannot
# prove no *other* publish happened. This observes the listing itself, so a
# change made outside the pipeline still surfaces.

locals {
  poller_image = join("", [
    "${var.region}-docker.pkg.dev/${var.project_id}",
    "/${google_artifact_registry_repository.poller.repository_id}/cws-poller:latest",
  ])
}

resource "google_artifact_registry_repository" "poller" {
  project       = var.project_id
  location      = var.region
  repository_id = "cws-poller"
  format        = "DOCKER"
  description   = "Container image for the Chrome Web Store status poller."

  # Tags stay mutable on purpose: the job references :latest and Cloud Run Jobs
  # re-resolve the tag on every execution, so a push is picked up on the next
  # tick without a redeploy. Enabling immutable tags would break that.

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  depends_on = [google_project_service.required]
}

# Push identity for the image build workflow, separate from both the CWS
# publisher and the job runtime. Building an image and publishing an extension
# are unrelated capabilities and should not share a principal: a compromised
# build must not be able to publish to the store.
resource "google_service_account" "image_publisher" {
  project      = var.project_id
  account_id   = "cws-image-publisher"
  display_name = "Chrome Web Store poller image publisher"
  description  = "GitHub Actions identity permitted only to push the poller image."

  depends_on = [google_project_service.required]
}

resource "google_service_account_iam_member" "image_publisher_github" {
  service_account_id = google_service_account.image_publisher.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

# Scoped to this repository, not the whole project: the build can push the
# poller image and nothing else.
resource "google_artifact_registry_repository_iam_member" "image_publisher_writer" {
  project    = var.project_id
  location   = google_artifact_registry_repository.poller.location
  repository = google_artifact_registry_repository.poller.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.image_publisher.email}"
}

# Runtime identity for the job, deliberately separate from cws-publisher.
#
# CWS allows only one service account per publisher, so the poller cannot have
# its own CWS identity - it must borrow the publisher's. Keeping a distinct
# runtime identity still buys two things: the impersonation is recorded as a
# GenerateAccessToken audit entry naming this account (a metadata-server token
# would be logged nowhere), and the poller's own IAM grants stay minimal.
resource "google_service_account" "poller" {
  project      = var.project_id
  account_id   = "cws-poller"
  display_name = "Chrome Web Store status poller"
  description  = "Cloud Run Job identity. Impersonates cws-publisher read-only."

  depends_on = [google_project_service.required]
}

# The poller borrows the publisher identity, but the container requests the
# chromewebstore.readonly scope. Per the v2 discovery document that scope is
# accepted only by fetchStatus - upload, publish, cancelSubmission and
# setPublishedDeployPercentage all require the full scope.
#
# Scope is chosen by the workload at token-request time and no IAM condition
# constrains it, so this bounds the blast radius of a bug rather than containing
# a fully compromised container. The audit entry is what makes misuse visible.
resource "google_service_account_iam_member" "poller_impersonates_publisher" {
  service_account_id = google_service_account.publisher.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.poller.email}"
}

# Required for logger.log_struct. Without it the poll succeeds and the snapshot
# is silently dropped, which is the exact failure the staleness rule must catch.
resource "google_project_iam_member" "poller_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.poller.email}"
}

resource "google_cloud_run_v2_job" "poller" {
  project             = var.project_id
  location            = var.region
  name                = "cws-poller"
  deletion_protection = false

  template {
    template {
      service_account = google_service_account.poller.email

      # The container already retries transient CWS errors with backoff. A
      # job-level retry would only duplicate the failure event and skew any
      # rule that counts them, so a failed execution stays a single failure.
      max_retries = 0

      # Shorter than the 5 minute schedule so a hung execution cannot overlap
      # the next tick.
      timeout = "240s"

      containers {
        image = local.poller_image

        # Cloud Run injects only K_SERVICE, K_REVISION and K_CONFIGURATION.
        # GOOGLE_CLOUD_PROJECT must be set explicitly.
        env {
          name  = "GOOGLE_CLOUD_PROJECT"
          value = var.project_id
        }

        env {
          name  = "CWS_PUBLISHER_ID"
          value = var.cws_publisher_id
        }

        env {
          name  = "CWS_EXTENSION_ID"
          value = var.cws_extension_id
        }

        env {
          name  = "CWS_IMPERSONATE_SERVICE_ACCOUNT"
          value = google_service_account.publisher.email
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
      }
    }
  }

  depends_on = [google_project_service.required]
}

# Separate identity for the trigger, so "who scheduled a run" and "what the run
# could do" are distinct principals in the audit log.
resource "google_service_account" "poller_scheduler" {
  project      = var.project_id
  account_id   = "cws-poller-scheduler"
  display_name = "Chrome Web Store poller scheduler"
  description  = "Cloud Scheduler identity permitted only to execute the poller job."

  depends_on = [google_project_service.required]
}

resource "google_cloud_run_v2_job_iam_member" "scheduler_invoker" {
  project  = var.project_id
  location = google_cloud_run_v2_job.poller.location
  name     = google_cloud_run_v2_job.poller.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.poller_scheduler.email}"
}

resource "google_cloud_scheduler_job" "poller" {
  project  = var.project_id
  region   = var.region
  name     = "cws-poller"
  schedule = var.poller_schedule

  # Absolute times keep the schedule stable across daylight saving changes.
  time_zone = "Etc/UTC"

  # Below the job timeout, so Scheduler does not give up mid-execution.
  attempt_deadline = "180s"

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri = join("", [
      "https://run.googleapis.com/v2/projects/${var.project_id}",
      "/locations/${var.region}/jobs/${google_cloud_run_v2_job.poller.name}:run",
    ])

    # Calling a Google API, so this needs an OAuth token rather than the OIDC
    # token used for a plain Cloud Run HTTPS endpoint.
    oauth_token {
      service_account_email = google_service_account.poller_scheduler.email
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.scheduler_invoker]
}

# Export path: Cloud Logging -> Pub/Sub -> Sentinel GCP connector.

resource "google_pubsub_topic" "cws_snapshots" {
  project = var.project_id
  name    = "cws-status-snapshots"

  depends_on = [google_project_service.required]
}

# Matches both cws_status_snapshot and cws_status_poll_failed: the poller writes
# both to the same log name, and the failure events are as important to the
# detection as the successful snapshots.
#
# The event_type guard drops the diagnostic entry google-cloud-logging writes
# under the same log name, which otherwise reaches Sentinel as an untyped
# message. Testing for presence rather than listing known values on purpose: an
# enumeration would silently stop exporting any event type added later, and a
# detection pipeline should fail noisy rather than quiet.
resource "google_logging_project_sink" "cws_snapshots" {
  project     = var.project_id
  name        = "cws-status-snapshots"
  destination = "pubsub.googleapis.com/${google_pubsub_topic.cws_snapshots.id}"

  filter = join(" AND ", [
    "logName=\"projects/${var.project_id}/logs/cws-status-snapshot\"",
    "jsonPayload.event_type:*",
  ])

  # Give the sink its own writer identity rather than the shared, broadly
  # privileged default log writer.
  unique_writer_identity = true
}

resource "google_pubsub_topic_iam_member" "sink_writer" {
  project = var.project_id
  topic   = google_pubsub_topic.cws_snapshots.name
  role    = "roles/pubsub.publisher"
  member  = google_logging_project_sink.cws_snapshots.writer_identity
}

resource "google_pubsub_subscription" "sentinel" {
  project = var.project_id
  name    = "cws-status-snapshots-sentinel"
  topic   = google_pubsub_topic.cws_snapshots.id

  # Long enough that a Sentinel connector outage over a weekend does not lose
  # snapshots and leave an unexplained gap in the detection timeline.
  message_retention_duration = "604800s" # 7 days
  ack_deadline_seconds       = 60

  expiration_policy {
    # Never expire. The default deletes a subscription after 31 days without a
    # consumer, which would quietly dismantle the export path.
    ttl = ""
  }
}
