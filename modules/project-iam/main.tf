# Per-environment runtime SA + IAM bindings
#
# Creates svc-ai-platform@{project} and grants it the roles needed
# for all Cloud Run services in that environment.

variable "project_id" {}
variable "environment" {}
variable "ops_project" {
  default = "rsr-ds-group-ops-d0b0"
}

resource "google_service_account" "svc_ai_platform" {
  project      = var.project_id
  account_id   = "svc-ai-platform"
  display_name = "AI Platform Service Account (${var.environment})"
}

# ── Cloud Run ────────────────────────────────────────────────
# Invoke any Cloud Run service in this project (service-to-service calls)
resource "google_project_iam_member" "run_invoker" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.svc_ai_platform.email}"
}

# ── BigQuery ─────────────────────────────────────────────────
# Read/write table data in own project
resource "google_project_iam_member" "bq_data_editor" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.svc_ai_platform.email}"
}

# Run queries in own project
resource "google_project_iam_member" "bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.svc_ai_platform.email}"
}

# ── Secret Manager ───────────────────────────────────────────
# Read shared secrets from OPS (brandwatch-api-key, thinknum-api-key, etc.)
resource "google_project_iam_member" "secrets_ops" {
  project = var.ops_project
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.svc_ai_platform.email}"
}

# Read secrets in own project
resource "google_project_iam_member" "secrets_own" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.svc_ai_platform.email}"
}

# ── Cross-project BQ WRITE (PRD only) ───────────────────────
resource "google_project_iam_member" "bq_cross_project_write" {
  for_each = toset(var.environment == "prd" ? ["rs-us-talentml2-qa-0001"] : [])
  project  = each.value
  role     = "roles/bigquery.dataEditor"
  member   = "serviceAccount:${google_service_account.svc_ai_platform.email}"
}

output "svc_ai_platform_email" {
  value = google_service_account.svc_ai_platform.email
}
