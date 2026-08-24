# Quarterly data refresh for the careerpath service.
#
# careerpath serves a computed columnar artifact (~2.1 GB), not a BigQuery table,
# so it can't use the data-sync scheduled-query path. Instead a manual Cloud Build
# trigger runs deploy/refresh-build.yaml (in the service repo): rebuild the
# artifact from BigQuery -> validate -> upload to gs://location_object -> re-run
# careerpath-dev so DEV redeploys with the fresh data. Cloud Scheduler fires it on
# the 2nd of Jan/Apr/Jul/Oct (the upstream table is recreated on the 1st).
#
# PRD is intentionally untouched — it stays a deliberate careerpath-v* tag.
#
# NOTE for review: the IAM members at the bottom are additive (member-level, not
# authoritative) grants the refresh needs beyond the analysis group's standard
# bindings. If IAM for build SAs is managed out-of-band (per the note in
# modules/build-service-account), move those to that process and drop them here.

data "google_project" "ops" {
  project_id = "rsr-ds-group-ops-d0b0"
}

resource "google_project_service" "cloud_scheduler" {
  project            = "rsr-ds-group-ops-d0b0"
  service            = "cloudscheduler.googleapis.com"
  disable_on_destroy = false
}

locals {
  careerpath_build_sa = module.build_sa["analysis"].build_sa_email
  careerpath_repo_uri = "https://github.com/randstadrisesmart/rsr-ds-careerpath"
}

# ── Manual trigger: rebuild + upload + redeploy ─────────────
# Not auto-fired (no push/pull_request); invoked by the scheduler below.
resource "google_cloudbuild_trigger" "careerpath_refresh" {
  project     = "rsr-ds-group-ops-d0b0"
  name        = "careerpath-refresh"
  location    = "global"
  description = "Quarterly: rebuild careerpath artifact from BigQuery, upload to GCS, redeploy DEV"

  source_to_build {
    uri       = local.careerpath_repo_uri
    ref       = "refs/heads/main"
    repo_type = "GITHUB"
  }

  git_file_source {
    path      = "deploy/refresh-build.yaml"
    uri       = local.careerpath_repo_uri
    revision  = "refs/heads/main"
    repo_type = "GITHUB"
  }

  service_account = "projects/rsr-ds-group-ops-d0b0/serviceAccounts/${local.careerpath_build_sa}"
}

# ── Cloud Scheduler: 06:00 UTC on the 2nd of Jan/Apr/Jul/Oct ─
resource "google_cloud_scheduler_job" "careerpath_refresh" {
  project   = "rsr-ds-group-ops-d0b0"
  region    = "us-east1"
  name      = "careerpath-refresh"
  schedule  = "0 6 2 1,4,7,10 *"
  time_zone = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "https://cloudbuild.googleapis.com/v1/projects/rsr-ds-group-ops-d0b0/locations/global/triggers/${google_cloudbuild_trigger.careerpath_refresh.trigger_id}:run"
    headers     = { "Content-Type" = "application/json" }
    body        = base64encode("{}")

    oauth_token {
      service_account_email = local.careerpath_build_sa
    }
  }

  depends_on = [google_project_service.cloud_scheduler]
}

# ── IAM the refresh needs (additive; see review note above) ──

# Cloud Scheduler mints OAuth tokens as the build SA to call the Cloud Build API.
resource "google_service_account_iam_member" "refresh_scheduler_token" {
  service_account_id = "projects/rsr-ds-group-ops-d0b0/serviceAccounts/${local.careerpath_build_sa}"
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.ops.number}@gcp-sa-cloudscheduler.iam.gserviceaccount.com"
}

# Running a trigger whose service_account is the build SA requires the caller
# (also the build SA — via scheduler, and again for the careerpath-dev re-run
# inside the build) to actAs that SA.
resource "google_service_account_iam_member" "refresh_self_actas" {
  service_account_id = "projects/rsr-ds-group-ops-d0b0/serviceAccounts/${local.careerpath_build_sa}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.careerpath_build_sa}"
}

# Run the careerpath-dev trigger (the redeploy step).
resource "google_project_iam_member" "refresh_builds_editor" {
  project = "rsr-ds-group-ops-d0b0"
  role    = "roles/cloudbuild.builds.editor"
  member  = "serviceAccount:${local.careerpath_build_sa}"
}

# Read the cp_output source table in DEV.
resource "google_project_iam_member" "refresh_bq_job_user" {
  project = "rsr-ds-group-dev-f193"
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${local.careerpath_build_sa}"
}

resource "google_project_iam_member" "refresh_bq_data_viewer" {
  project = "rsr-ds-group-dev-f193"
  role    = "roles/bigquery.dataViewer"
  member  = "serviceAccount:${local.careerpath_build_sa}"
}

# Write the rebuilt artifact to the shared bucket the DEV image bakes from.
resource "google_storage_bucket_iam_member" "refresh_gcs_writer" {
  bucket = "location_object"
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${local.careerpath_build_sa}"
}
