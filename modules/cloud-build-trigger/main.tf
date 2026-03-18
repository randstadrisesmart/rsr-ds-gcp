# Per-service Cloud Build triggers (pr + dev + prod)
#
# PR:   fires on pull request to main → test + lint only
# Dev:  fires on push to main → build + deploy to DEV
# Prod: fires on tag matching {service}-v* → manual approval → deploy to PRD

variable "service_name" {}
variable "github_repo" {}
variable "github_owner" {
  default = "randstadrisesmart"
}
variable "region" {
  default = "us-east1"
}
variable "build_sa" {
  description = "Per-service build SA email"
}
variable "iap" {
  default = false
}

# PR trigger: fires on pull request to main (test + lint only)
resource "google_cloudbuild_trigger" "pr" {
  project  = "rsr-ds-group-ops-d0b0"
  name     = "${var.service_name}-pr"
  location = "global"

  github {
    owner = var.github_owner
    name  = var.github_repo

    pull_request {
      branch = "^main$"
    }
  }

  filename        = "deploy/pr-build.yaml"
  service_account = "projects/rsr-ds-group-ops-d0b0/serviceAccounts/${var.build_sa}"
}

# Dev trigger: fires on push to main
resource "google_cloudbuild_trigger" "dev" {
  project  = "rsr-ds-group-ops-d0b0"
  name     = "${var.service_name}-dev"
  location = "global"

  github {
    owner = var.github_owner
    name  = var.github_repo

    push {
      branch = "^main$"
    }
  }

  filename        = "deploy/dev-build.yaml"
  service_account = "projects/rsr-ds-group-ops-d0b0/serviceAccounts/${var.build_sa}"

  substitutions = {
    _SERVICE_NAME = var.service_name
    _REGION       = var.region
    _PROJECT_DEV  = "rsr-ds-group-dev-f193"
    _ENV          = "dev"
    _IAP          = tostring(var.iap)
  }
}

# Prod trigger: fires on tag matching {service}-v*
resource "google_cloudbuild_trigger" "prd" {
  project  = "rsr-ds-group-ops-d0b0"
  name     = "${var.service_name}-prd"
  location = "global"

  github {
    owner = var.github_owner
    name  = var.github_repo

    push {
      tag = "^${var.service_name}-v\\d+\\.\\d+\\.\\d+$"
    }
  }

  filename        = "deploy/prod-build.yaml"
  service_account = "projects/rsr-ds-group-ops-d0b0/serviceAccounts/${var.build_sa}"

  approval_config {
    approval_required = true
  }

  substitutions = {
    _SERVICE_NAME = var.service_name
    _REGION       = var.region
    _PROJECT_DEV  = "rsr-ds-group-dev-f193"
    _PROJECT_PRD  = "rsr-ds-group-prd-83ad"
    _ENV          = "prd"
    _IAP          = tostring(var.iap)
  }
}
