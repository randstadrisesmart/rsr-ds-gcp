# Per-service Cloud Build service account
#
# Creates one SA per service in OPS. The 8 cross-project IAM bindings
# (4 DEV + 3 PRD + 1 OPS) are provisioned by the infra team per request
# (option 2 from request.txt).

variable "service_name" {}
variable "project_ops" {
  default = "rsr-ds-group-ops-d0b0"
}
variable "build_status_topic" {
  description = "PubSub topic name for build status notifications"
}

resource "google_service_account" "build" {
  project      = var.project_ops
  account_id   = "svc-build-${var.service_name}"
  display_name = "Cloud Build SA for ${var.service_name}"
}

# Read SSH deploy key from OPS Secret Manager
resource "google_secret_manager_secret_iam_member" "deploy_key" {
  project   = var.project_ops
  secret_id = "ssh-deploy-key-${var.service_name}"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.build.email}"
}

# Publish build status notifications to OPS PubSub topic
resource "google_pubsub_topic_iam_member" "build_notify" {
  project = var.project_ops
  topic   = var.build_status_topic
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.build.email}"
}

output "build_sa_email" {
  value = google_service_account.build.email
}
