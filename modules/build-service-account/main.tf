# Per-group Cloud Build service account
#
# Creates one SA per build group in OPS (e.g. svc-build-ollama, svc-build-talent).
# Multiple services share the same SA within a group.
# The 8 cross-project IAM bindings (4 DEV + 3 PRD + 1 OPS) are provisioned
# by the infra team once per group.

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
