# Cloud Run service definition
#
# Deploys a single Cloud Run service. Used in environment configs
# to define per-service settings (min/max instances, env vars, etc.).
#
# Note: Cloud Build handles the actual image deployment. This module
# ensures the service exists with the right configuration.

variable "project_id" {}
variable "service_name" {}
variable "region" {
  default = "us-east1"
}
variable "image" {}
variable "service_account" {}
variable "min_instances" {
  default = 0
}
variable "max_instances" {
  default = 4
}
variable "env_vars" {
  type    = map(string)
  default = {}
}

resource "google_cloud_run_v2_service" "service" {
  project  = var.project_id
  name     = var.service_name
  location = var.region

  template {
    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    service_account = var.service_account

    containers {
      image = var.image

      dynamic "env" {
        for_each = var.env_vars
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }

  # Don't allow unauthenticated access
  lifecycle {
    ignore_changes = [
      # Cloud Build updates the image on every deploy — don't fight it
      template[0].containers[0].image,
    ]
  }
}

# Block public access
resource "google_cloud_run_v2_service_iam_member" "no_public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.service.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${var.service_account}"
}

output "url" {
  value = google_cloud_run_v2_service.service.uri
}
