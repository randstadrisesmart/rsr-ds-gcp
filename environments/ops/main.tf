terraform {
  backend "gcs" {
    bucket = "rsr-ds-group-ops-terraform-state"
    prefix = "ops"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = "rsr-ds-group-ops-d0b0"
  region  = "us-east1"
}

# ── Terraform state bucket ──────────────────────────────────

resource "google_storage_bucket" "terraform_state" {
  project  = "rsr-ds-group-ops-d0b0"
  name     = "rsr-ds-group-ops-terraform-state"
  location = "US"

  versioning {
    enabled = true
  }
}

# ── PubSub topic for dev→prod pipeline triggering ───────────

resource "google_pubsub_topic" "build_status" {
  project = "rsr-ds-group-ops-d0b0"
  name    = "pipelines_build_status"
}

# ── Artifact Registry (one per environment, shared by all services) ──

resource "google_artifact_registry_repository" "dev_docker" {
  project       = "rsr-ds-group-dev-f193"
  location      = "us-east1"
  repository_id = "docker-images"
  format        = "DOCKER"
}

resource "google_artifact_registry_repository" "prd_docker" {
  project       = "rsr-ds-group-prd-83ad"
  location      = "us-east1"
  repository_id = "docker-images"
  format        = "DOCKER"
}

resource "google_artifact_registry_repository" "dev_docker_us_central1" {
  project       = "rsr-ds-group-dev-f193"
  location      = "us-central1"
  repository_id = "docker-images"
  format        = "DOCKER"
}

resource "google_artifact_registry_repository" "prd_docker_us_central1" {
  project       = "rsr-ds-group-prd-83ad"
  location      = "us-central1"
  repository_id = "docker-images"
  format        = "DOCKER"
}

resource "google_artifact_registry_repository" "dev_docker_europe_west1" {
  project       = "rsr-ds-group-dev-f193"
  location      = "europe-west1"
  repository_id = "docker-images"
  format        = "DOCKER"
}

resource "google_artifact_registry_repository" "prd_docker_europe_west1" {
  project       = "rsr-ds-group-prd-83ad"
  location      = "europe-west1"
  repository_id = "docker-images"
  format        = "DOCKER"
}

# ── Data sync SA ────────────────────────────────────────────

resource "google_service_account" "data_sync" {
  project      = "rsr-ds-group-ops-d0b0"
  account_id   = "svc-ai-platform-ops"
  display_name = "AI Platform Ops SA (BQ data sync scheduled queries)"
}

# ── Build failure alert ─────────────────────────────────────

resource "google_monitoring_alert_policy" "build_failures" {
  project      = "rsr-ds-group-ops-d0b0"
  display_name = "Cloud Build Failures"
  combiner     = "OR"

  conditions {
    display_name = "Build failed"
    condition_matched_log {
      filter = <<-EOF
        resource.type="build"
        severity>=ERROR
      EOF
    }
  }

  # TODO: set notification_channels once Slack channel is configured
  # notification_channels = [var.slack_channel_id]

  alert_strategy {
    notification_rate_limit {
      period = "3600s"
    }
  }
}
