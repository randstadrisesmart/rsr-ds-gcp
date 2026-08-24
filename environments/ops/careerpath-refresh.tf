# Quarterly data refresh for the careerpath service.
#
# careerpath serves a computed columnar artifact (~2.1 GB), not a BigQuery table,
# so it can't use the data-sync scheduled-query path. A manual Cloud Build trigger
# runs deploy/refresh-build.yaml (in the service repo): rebuild the artifact from
# BigQuery -> validate -> upload to gs://location_object -> re-run careerpath-dev
# so DEV redeploys with the fresh data. Cloud Scheduler fires it on the 2nd of
# Jan/Apr/Jul/Oct (the upstream table is recreated on the 1st).
#
# PRD is intentionally untouched — it stays a deliberate careerpath-v* tag.
#
# ─────────────────────────────────────────────────────────────────────────────
# Managed here: the Cloud Build trigger + the two SA-level IAM bindings the
# Terraform runner is allowed to create. The Cloud Scheduler job and the
# project/bucket IAM are provisioned OUT-OF-BAND — the runner's role covers
# neither (matching the note in modules/build-service-account).
#
# Out-of-band, already done manually:
#   - cloudscheduler.googleapis.com enabled on ops
#   - Cloud Scheduler job "careerpath-refresh" (us-east1) -> runs this trigger,
#     schedule "0 6 2 1,4,7,10 *", OAuth as the build SA. To bring under Terraform
#     later: terraform import google_cloud_scheduler_job.careerpath_refresh \
#       projects/rsr-ds-group-ops-d0b0/locations/us-east1/jobs/careerpath-refresh
#
# Out-of-band, STILL NEEDED (infra team) — grant to
# svc-build-analysis@rsr-ds-group-ops-d0b0.iam.gserviceaccount.com:
#   - roles/bigquery.jobUser         on rsr-ds-group-dev-f193   (run the query)
#   - roles/bigquery.dataViewer      on rsr-ds-group-dev-f193   (read cp_output)
#   - roles/storage.objectAdmin      on bucket location_object  (upload artifact)
#   - roles/cloudbuild.builds.editor on rsr-ds-group-ops-d0b0   (re-run careerpath-dev)
# Until these land, a scheduled refresh 403s at the BigQuery / GCS / redeploy step.
# ─────────────────────────────────────────────────────────────────────────────

data "google_project" "ops" {
  project_id = "rsr-ds-group-ops-d0b0"
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

# Cloud Scheduler job "careerpath-refresh" is created out-of-band (see header) —
# it targets this trigger's :run endpoint on schedule "0 6 2 1,4,7,10 *".

# ── SA-level IAM (the runner CAN manage these) ──────────────

# Cloud Scheduler mints OAuth tokens as the build SA to call the Cloud Build API.
resource "google_service_account_iam_member" "refresh_scheduler_token" {
  service_account_id = "projects/rsr-ds-group-ops-d0b0/serviceAccounts/${local.careerpath_build_sa}"
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.ops.number}@gcp-sa-cloudscheduler.iam.gserviceaccount.com"
}

# Running a trigger whose service_account is the build SA requires the caller
# (also the build SA — via the scheduler, and again for the careerpath-dev re-run
# inside the build) to actAs that SA.
resource "google_service_account_iam_member" "refresh_self_actas" {
  service_account_id = "projects/rsr-ds-group-ops-d0b0/serviceAccounts/${local.careerpath_build_sa}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.careerpath_build_sa}"
}
