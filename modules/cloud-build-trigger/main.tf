# Per-service Cloud Build triggers (pr + dev + prod)
#
# PR:   fires on pull request to main → test + lint only
# Dev:  fires on push to main → build + deploy to DEV
# Prod: fires on tag matching {service}-v* → manual approval → deploy to PRD
#
# A monorepo component (var.path) reads its configs from <path>/deploy/ and
# keeps the same three triggers; every trigger on the repo fires on every PR or
# push, whichever folder changed (Cloud Build filters by file only with
# included_files, not used here). Components without a dev or prod config keep
# the trigger disabled rather than absent, so nothing has to be renamed later.

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
variable "path" {
  description = "Subfolder of the repo that holds this component (monorepos). Empty for a repo that IS the service. The build configs are read from <path>/deploy/*.yaml and the trigger names are <service>-{pr,dev,prd} as always."
  default     = ""
}
variable "comment_control" {
  description = "PR builds wait for a collaborator to comment /gcbrun before running (Cloud Build comment control). Off for every repo-per-service; the taxonomy monorepo was created with it on."
  default     = false
}
variable "dev_enabled" {
  description = "false: the push-to-main trigger exists but never fires (a component without deploy/dev-build.yaml, deployed by hand)."
  default     = true
}
variable "prd_enabled" {
  description = "false: the tag trigger exists but never fires (a component without deploy/prod-build.yaml)."
  default     = true
}

variable "descriptions" {
  description = "Optional description per trigger, keyed pr / dev / prd (kept for triggers adopted from the console)."
  type        = map(string)
  default     = {}
}

locals {
  config_dir = var.path == "" ? "deploy" : "${var.path}/deploy"
}

# PR trigger: fires on pull request to main (test + lint only)
resource "google_cloudbuild_trigger" "pr" {
  project     = "rsr-ds-group-ops-d0b0"
  name        = "${var.service_name}-pr"
  description = lookup(var.descriptions, "pr", null)
  location    = "global"

  github {
    owner = var.github_owner
    name  = var.github_repo

    pull_request {
      branch          = "^main$"
      comment_control = var.comment_control ? "COMMENTS_ENABLED" : null
    }
  }

  filename        = "${local.config_dir}/pr-build.yaml"
  service_account = "projects/rsr-ds-group-ops-d0b0/serviceAccounts/${var.build_sa}"
}

# Dev trigger: fires on push to main
resource "google_cloudbuild_trigger" "dev" {
  project     = "rsr-ds-group-ops-d0b0"
  name        = "${var.service_name}-dev"
  description = lookup(var.descriptions, "dev", null)
  location    = "global"

  github {
    owner = var.github_owner
    name  = var.github_repo

    push {
      branch = "^main$"
    }
  }

  disabled        = !var.dev_enabled
  filename        = "${local.config_dir}/dev-build.yaml"
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
  project     = "rsr-ds-group-ops-d0b0"
  name        = "${var.service_name}-prd"
  description = lookup(var.descriptions, "prd", null)
  location    = "global"

  github {
    owner = var.github_owner
    name  = var.github_repo

    push {
      tag = "^${var.service_name}-v\\d+\\.\\d+\\.\\d+$"
    }
  }

  disabled        = !var.prd_enabled
  filename        = "${local.config_dir}/prod-build.yaml"
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
