# Per-service Cloud Build service account + IAM bindings
#
# Creates one SA per service in OPS, grants it the 7 roles needed to
# build in DEV and deploy to both DEV and PRD.

variable "service_name" {}
variable "project_ops" {
  default = "rsr-ds-group-ops-d0b0"
}
variable "project_dev" {
  default = "rsr-ds-group-dev-f193"
}
variable "project_prd" {
  default = "rsr-ds-group-prd-83ad"
}

resource "google_service_account" "build" {
  project      = var.project_ops
  account_id   = "svc-build-${var.service_name}"
  display_name = "Cloud Build SA for ${var.service_name}"
}

# Push images to DEV AR
resource "google_project_iam_member" "ar_writer_dev" {
  project = var.project_dev
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Deploy to DEV Cloud Run
resource "google_project_iam_member" "run_admin_dev" {
  project = var.project_dev
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Act as runtime SA in DEV
resource "google_project_iam_member" "sa_user_dev" {
  project = var.project_dev
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Read images from DEV AR (for copy step in prod build)
resource "google_project_iam_member" "ar_reader_dev" {
  project = var.project_dev
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Copy images to PRD AR
resource "google_project_iam_member" "ar_writer_prd" {
  project = var.project_prd
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Deploy to PRD Cloud Run
resource "google_project_iam_member" "run_admin_prd" {
  project = var.project_prd
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Act as runtime SA in PRD
resource "google_project_iam_member" "sa_user_prd" {
  project = var.project_prd
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Read SSH deploy key from OPS Secret Manager
resource "google_secret_manager_secret_iam_member" "deploy_key" {
  project   = var.project_ops
  secret_id = "ssh-deploy-key-${var.service_name}"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.build.email}"
}

output "build_sa_email" {
  value = google_service_account.build.email
}
