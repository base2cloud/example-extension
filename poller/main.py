"""
CWS fetchStatus poller — Cloud Run Job.

Calls the Chrome Web Store Publish API v2 fetchStatus endpoint to snapshot
the current live version and rollout percentage, then emits a structured log
entry to Cloud Logging.

The log sink routes entries with logName "cws-status-snapshot" to Pub/Sub,
which feeds the Sentinel GCP connector. Sentinel's KQL rule diffs consecutive
snapshots and joins against STS audit events to detect out-of-band changes.

Because this is a detection control, a failed poll is itself a finding: every
error path emits a cws_status_poll_failed event rather than exiting silently.
Absence of events must be alertable too - see the staleness rule note in
terraform/README.md - since a poller that dies quietly disables detection.
"""

import json
import os
import sys
import time
from datetime import datetime, timezone

import google.auth
import google.auth.transport.requests
import requests
from google.auth import impersonated_credentials
from google.cloud import logging as gcp_logging

LOG_NAME = "cws-status-snapshot"

# readonly scope is sufficient — the poller never writes to the store. Per the
# v2 discovery document, fetchStatus accepts chromewebstore.readonly, while
# upload/publish/cancelSubmission/setPublishedDeployPercentage require the full
# chromewebstore scope. A token minted here therefore cannot alter the listing.
CWS_SCOPE = "https://www.googleapis.com/auth/chromewebstore.readonly"

RETRYABLE_STATUS = frozenset({429, 500, 502, 503, 504})
MAX_ATTEMPTS = 4
BACKOFF_BASE_SECONDS = 2.0
REQUEST_TIMEOUT_SECONDS = 30


class ConfigError(RuntimeError):
    """Raised when required configuration is missing or unusable."""


class Config:
    """Runtime configuration, resolved once at startup."""

    def __init__(
        self,
        project_id: str,
        publisher_id: str,
        extension_id: str,
        impersonate_service_account: str | None,
    ) -> None:
        self.project_id = project_id
        self.publisher_id = publisher_id
        self.extension_id = extension_id
        self.impersonate_service_account = impersonate_service_account

    @property
    def fetch_status_url(self) -> str:
        # v2 fetchStatus: returns publishedItemRevisionStatus +
        # submittedItemRevisionStatus.
        return (
            f"https://chromewebstore.googleapis.com/v2"
            f"/publishers/{self.publisher_id}/items/{self.extension_id}:fetchStatus"
        )


def _require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ConfigError(f"required environment variable {name} is unset or empty")
    return value


def _resolve_project_id() -> str:
    """
    Cloud Run does not inject GOOGLE_CLOUD_PROJECT - it sets only K_SERVICE,
    K_REVISION and K_CONFIGURATION. Terraform sets it explicitly, but fall back
    to the project ADC reports so a missing variable degrades to a lookup
    rather than crashing the job before it can report anything.
    """
    explicit = os.environ.get("GOOGLE_CLOUD_PROJECT", "").strip()
    if explicit:
        return explicit

    _, detected = google.auth.default()
    if not detected:
        raise ConfigError(
            "project id unavailable: set GOOGLE_CLOUD_PROJECT or run with "
            "credentials that carry a project"
        )
    return detected


def load_config() -> Config:
    return Config(
        project_id=_resolve_project_id(),
        publisher_id=_require_env("CWS_PUBLISHER_ID"),
        extension_id=_require_env("CWS_EXTENSION_ID"),
        # When set, the job authenticates as its own identity and impersonates
        # the CWS-linked service account. That extra hop is deliberate: metadata
        # server tokens produce no audit entry, whereas impersonation writes a
        # GenerateAccessToken record naming the caller, so each poll is
        # attributable and distinguishable from a pipeline publish.
        impersonate_service_account=os.environ.get(
            "CWS_IMPERSONATE_SERVICE_ACCOUNT", ""
        ).strip()
        or None,
    )


def get_access_token(config: Config) -> str:
    request = google.auth.transport.requests.Request()

    if config.impersonate_service_account:
        source_credentials, _ = google.auth.default()
        credentials = impersonated_credentials.Credentials(
            source_credentials=source_credentials,
            target_principal=config.impersonate_service_account,
            target_scopes=[CWS_SCOPE],
        )
    else:
        # Running directly as the CWS-linked service account. Cloud Run's
        # metadata server honours requested scopes (Compute Engine's does not),
        # so the readonly scope is applied rather than silently widened.
        credentials, _ = google.auth.default(scopes=[CWS_SCOPE])

    credentials.refresh(request)
    return credentials.token


def fetch_cws_status(config: Config, token: str) -> dict:
    """
    GET fetchStatus with bounded retries.

    A transient failure that drops a snapshot is a gap in the detection
    timeline, so retry rather than let one blip create a blind spot.
    """
    headers = {"Authorization": f"Bearer {token}"}
    last_error: Exception | None = None

    for attempt in range(MAX_ATTEMPTS):
        is_last = attempt == MAX_ATTEMPTS - 1
        try:
            resp = requests.get(
                config.fetch_status_url,
                headers=headers,
                timeout=REQUEST_TIMEOUT_SECONDS,
            )
            if resp.status_code in RETRYABLE_STATUS and not is_last:
                last_error = requests.HTTPError(
                    f"retryable status {resp.status_code}", response=resp
                )
            else:
                resp.raise_for_status()
                return resp.json()
        except requests.RequestException as exc:
            last_error = exc
            if is_last:
                raise

        time.sleep(BACKOFF_BASE_SECONDS * (2**attempt))

    # Only reachable when the final attempt was a retryable status.
    raise last_error if last_error else RuntimeError("fetchStatus failed")


def _parse_revision(revision: dict | None) -> dict:
    """Extract version and rollout percentage from an ItemRevisionStatus object."""
    if not revision:
        return {
            "version": None,
            "rollout_pct": None,
            "state": None,
            "channel_count": 0,
            "channels": [],
        }

    channels = revision.get("distributionChannels", []) or []

    # CWS normally exposes a single channel, but deployPercentage exists
    # precisely because staged rollouts can split traffic. Picking channels[0]
    # would track an arbitrary one and silently mask a change in another, so
    # select the dominant channel deterministically and surface the count for
    # the detection rule to flag.
    def _rank(channel: dict) -> tuple[int, str]:
        pct = channel.get("deployPercentage")
        return (pct if isinstance(pct, int) else 100, str(channel.get("crxVersion") or ""))

    dominant = max(channels, key=_rank) if channels else {}

    return {
        "version": dominant.get("crxVersion"),
        # deployPercentage is 0-100 during a staged rollout; absent when fully live.
        "rollout_pct": dominant.get("deployPercentage"),
        "state": revision.get("state"),
        "channel_count": len(channels),
        "channels": [
            {
                "version": c.get("crxVersion"),
                "rollout_pct": c.get("deployPercentage"),
            }
            for c in channels
        ],
    }


def extract_snapshot(config: Config, response: dict) -> dict:
    """
    Normalise the v2 fetchStatus response into the fixed schema the Sentinel
    KQL rule expects.

    published  — what users are currently running
    submitted  — pending review/staged (None when nothing is in-flight)
    """
    published = _parse_revision(response.get("publishedItemRevisionStatus"))
    submitted = _parse_revision(response.get("submittedItemRevisionStatus"))

    return {
        "event_type": "cws_status_snapshot",
        "publisher_id": config.publisher_id,
        "extension_id": config.extension_id,
        # Published (live) revision
        "published_version": published["version"],
        "published_rollout_pct": published["rollout_pct"],
        "published_state": published["state"],
        # A count above 1 means the scalars above describe only the dominant
        # channel; the rule should treat that as needing a closer look.
        "published_channel_count": published["channel_count"],
        "published_channels": published["channels"],
        # Submitted (pending) revision — present during uploads/review cycles
        "submitted_version": submitted["version"],
        "submitted_state": submitted["state"],
        # Correlates a snapshot with an in-flight pipeline upload.
        "last_async_upload_state": response.get("lastAsyncUploadState"),
        # Policy flags
        "taken_down": response.get("takenDown", False),
        "warned": response.get("warned", False),
        "ts": datetime.now(timezone.utc).isoformat(),
    }


def _make_logger(project_id: str):
    client = gcp_logging.Client(project=project_id)
    return client.logger(LOG_NAME)


def emit(logger, payload: dict, severity: str = "INFO") -> None:
    logger.log_struct(payload, severity=severity)


def _failure_event(config: Config | None, exc: Exception) -> dict:
    """
    Emitted instead of exiting silently. Without this a broken poll and a
    genuinely unchanged listing are indistinguishable downstream, which would
    let anyone who can break the poller blind the detection.
    """
    status_code = None
    detail = str(exc)
    if isinstance(exc, requests.HTTPError) and exc.response is not None:
        status_code = exc.response.status_code
        detail = exc.response.text

    return {
        "event_type": "cws_status_poll_failed",
        "publisher_id": config.publisher_id if config else None,
        "extension_id": config.extension_id if config else None,
        "error_class": type(exc).__name__,
        "http_status": status_code,
        "detail": detail[:2000],
        "ts": datetime.now(timezone.utc).isoformat(),
    }


def main() -> int:
    try:
        config = load_config()
        logger = _make_logger(config.project_id)
    except Exception as exc:
        # Nothing to emit through - the sink is not reachable without config.
        print(f"Fatal: configuration error: {exc}", file=sys.stderr)
        return 1

    try:
        token = get_access_token(config)
        response = fetch_cws_status(config, token)
        snapshot = extract_snapshot(config, response)
    except Exception as exc:
        print(f"Poll failed: {exc}", file=sys.stderr)
        try:
            emit(logger, _failure_event(config, exc), severity="ERROR")
        except Exception as emit_exc:
            print(f"Fatal: could not emit failure event: {emit_exc}", file=sys.stderr)
        return 1

    try:
        emit(logger, snapshot)
    except Exception as exc:
        print(f"Fatal: could not emit snapshot: {exc}", file=sys.stderr)
        return 1

    # Also print to stdout so Cloud Run job logs capture it for debugging.
    print(json.dumps(snapshot, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
