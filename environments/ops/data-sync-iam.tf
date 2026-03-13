# IAM for the OPS data sync SA (svc-ai-platform-ops)
#
# Project-level IAM bindings (bigquery.jobUser on OPS, bigquery.dataViewer
# on DEV, bigquery.dataOwner on PRD) are provisioned by the infra team
# per option 2 and are NOT managed by Terraform.

# Allow Terraform SA to impersonate the sync SA
# so the post-apply step can trigger BQ scheduled queries
resource "google_service_account_iam_member" "cloudbuild_impersonate_sync" {
  service_account_id = google_service_account.data_sync.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:rsr-ds-group-ops-d0b0@appspot.gserviceaccount.com"
}
