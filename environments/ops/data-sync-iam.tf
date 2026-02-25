# IAM for the OPS data sync SA (svc-ai-platform-ops)
#
# Runs the nightly BQ Scheduled Queries that zero-copy clone DEV → PRD.

# Run scheduled queries in OPS
resource "google_project_iam_member" "sync_job_user" {
  project = "rsr-ds-group-ops-d0b0"
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.data_sync.email}"
}

# Read source tables in DEV
resource "google_project_iam_member" "sync_read_dev" {
  project = "rsr-ds-group-dev-f193"
  role    = "roles/bigquery.dataViewer"
  member  = "serviceAccount:${google_service_account.data_sync.email}"
}

# Create datasets + write cloned tables in PRD
resource "google_project_iam_member" "sync_write_prd" {
  project = "rsr-ds-group-prd-83ad"
  role    = "roles/bigquery.dataOwner"
  member  = "serviceAccount:${google_service_account.data_sync.email}"
}
