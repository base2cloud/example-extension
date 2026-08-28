# Terraform — CWS publish infrastructure

All GCP infrastructure backing the Chrome Web Store publish pipeline lives here.

## Layout

| Path         | State         | Purpose                                                      |
| ------------ | ------------- | ------------------------------------------------------------ |
| `bootstrap/` | local         | Creates the GCS bucket that holds the workload module's state. |
| `workload/`  | `gcs` backend | Everything else: APIs, WIF, service account, secrets, IAM.     |

Neither directory is a parent of the other — they are two independent root
modules, applied separately.

`bootstrap/` exists only to break the chicken-and-egg problem: the workload
module stores its state in a bucket, and something has to create that bucket
first. It is run once and then left alone. Its local state describes nothing but
the bucket, so losing it costs a single `terraform import`.

The workload module's state lives at the `cws-publish` prefix in that bucket.
The prefix names the workload's purpose and is independent of the directory
name; renaming the directory does not move the state.

## Prerequisite: the GCP project

The project is **not** managed by Terraform. A `terraform destroy` should never
be able to delete the project, and the state bucket lives inside the project it
would be managing. The workload module reads it through a `data
"google_project"` lookup instead.

The project used by this repo already exists:

| Field          | Value                     |
| -------------- | ------------------------- |
| Project name   | `chrome-extension`        |
| Project ID     | `chrome-extension-506804` |
| Project number | `346608605237`            |
| Parent         | none (no organization)    |

To recreate it from scratch:

```bash
# Project IDs are globally unique; --name is the display name.
gcloud projects create chrome-extension-506804 --name=chrome-extension

# Billing must be linked before any API can be enabled.
gcloud billing accounts list
gcloud billing projects link chrome-extension-506804 \
  --billing-account=<BILLING_ACCOUNT_ID>
```

Then update `project_id` in both `terraform.tfvars` files and the `bucket` in
`workload/versions.tf`'s backend block.

## Usage

Authenticate once with application default credentials:

```bash
gcloud auth application-default login
```

Create the state bucket (one time only):

```bash
cd terraform/bootstrap
terraform init
terraform apply
```

Then run the workload module:

```bash
cd terraform/workload
terraform init
terraform plan
terraform apply
```

## Workload Identity Federation

GitHub Actions authenticates by exchanging its OIDC token for a short-lived
Google credential. No service account key exists, so there is no long-lived
credential to leak or rotate.

The token exchange is gated by this CEL condition on the provider:

```
assertion.repository  == "base2cloud/example-extension" &&
assertion.ref         == "refs/heads/main"              &&
assertion.environment == "prd"
```

All three must hold. `ref` and `environment` are independent claims, so
requiring both is not redundant — `ref` pins *what code* runs, `environment`
pins *that a human approved it*. A job that omits `environment:` produces a
token with no environment claim and is refused, so review cannot be skipped by
editing the workflow.

Impersonation is gated a second time by the IAM binding on the service account,
whose `principalSet` is scoped to `attribute.repository`. If the provider
condition were ever loosened, that binding still restricts access to this repo.

## Chrome Web Store authentication

The pipeline uses the **CWS v2 API with service account authentication**. There
is no OAuth client id, client secret, or refresh token at any point.

`google-github-actions/auth` mints an access token for `cws-publisher` scoped to
`https://www.googleapis.com/auth/chromewebstore`, and CWS accepts that token
directly:

```
GitHub OIDC token
  -> GCP STS (attribute condition enforced here)
  -> impersonate cws-publisher
  -> access token, chromewebstore scope only
  -> https://chromewebstore.googleapis.com/upload/v2/...
```

Every credential in that chain is minted per-run and expires within the hour.

### Chrome Web Store dashboard prerequisites

These cannot be expressed in Terraform — CWS has no API for its own account
settings.

1. The service account email must be added under **Account** in the
   [Developer Dashboard](https://chrome.google.com/webstore/devconsole):
   `cws-publisher@chrome-extension-506804.iam.gserviceaccount.com`
2. The publisher ID from **Publisher > Settings** must be set as the
   `CWS_PUBLISHER_ID` repository variable. The v2 API puts it in the URL path.
3. 2-Step Verification must be enabled on the owning Google account. Google
   requires this before a service account may publish on its behalf, which
   makes it a production control rather than a personal preference.

Note: **only one service account may be linked per publisher.** Splitting dev
and prod service accounts would require separate publisher accounts.

### V1.1 sunset

The old `www.googleapis.com/.../chromewebstore/v1.1/` endpoints stop working on
**15 October 2026**. This workflow already uses v2.

### GitHub-side prerequisites

The Terraform above is inert until the repository is configured to match:

1. ~~An Environment named `prd` must exist, with **required reviewers** set and
   its deployment branches limited to `main`.~~ Done — reviewer
   `cdivitotawela`, branch policy `main`.
2. `main` must have branch protection. **Still outstanding.** The `ref` clause
   only proves the code came from `main`; it says nothing about who was allowed
   to put it there.
3. The publishing job must declare `environment: prd`, or its token will not
   satisfy the condition. Applied when the workflow is rewritten.

The environment name is set by `github_environment` in `terraform.tfvars` and
must stay identical to the Environment name in GitHub. They are two independent
systems agreeing on a string; a typo on either side fails the exchange with a
generic permission error.

## Detection: the CWS status poller

`poller/` is a Cloud Run Job that snapshots `fetchStatus` into Cloud Logging
under the log name `cws-status-snapshot`, routed by sink to Pub/Sub and on to
Sentinel. Diffing consecutive snapshots and joining against STS audit events
detects a publish that did **not** come through the pipeline.

The STS log proves a given publish happened through WIF. It cannot prove no
*other* publish happened. The poller is what closes that gap, by observing the
listing itself rather than the path used to change it.

It authenticates with `chromewebstore.readonly`. Per the v2 discovery document
only `fetchStatus` accepts that scope — `upload`, `publish`, `cancelSubmission`
and `setPublishedDeployPercentage` all require the full `chromewebstore` scope.
So a token minted by the poller cannot alter the listing. Note this is a
workload-level control: the scope is chosen at token-request time and no IAM
condition constrains it, so it bounds the blast radius of a bug rather than
containing a fully compromised container.

### Two alerting rules are required, not one

- **Change detection** — consecutive snapshots differ without a corresponding
  STS exchange.
- **Staleness** — no snapshot received within N intervals.

The second is not optional. Every poller error emits a
`cws_status_poll_failed` event rather than exiting silently, but a job that
never starts emits nothing at all. Without a staleness rule, killing the poller
silently disables the detection, and absence of alerts reads as "no changes".

Detection resolution is bounded by the poll interval: a change made and
reverted between two polls is invisible. That makes the schedule a
threat-model decision, not a cost one.

## Conventions

- **No secrets anywhere.** Not in Terraform, not in GitHub, not in Secret
  Manager. See "Chrome Web Store authentication" below — the design has no
  long-lived credential to store. Terraform state is therefore free of
  sensitive values, which matters because state is plain JSON with every
  attribute in the clear.
- **`disable_on_destroy = false`** on every `google_project_service`. Disabling
  an API deletes the resources that depend on it, project-wide.
- **One API, one owner.** `cloudresourcemanager.googleapis.com` is enabled by
  `bootstrap/` and nowhere else, because the workload module's `data
  "google_project"` lookup needs it in order to plan at all. Declaring it in
  both modules would leave a single API claimed by two states.
- The provider is pinned to the `7.x` line. `8.0.0` is available but only days
  old; move once it has settled.
