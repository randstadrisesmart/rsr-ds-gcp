# artifact-registry-cleanup: delete container images nothing points at
#
# Artifact Registry keeps every image ever pushed; on 2026-10-27 the two
# docker-images repos held 1,029 GB, of which about 950 GB was old builds no
# Cloud Run revision used (ollama and cleanpii alone: 59 versions, 820 GB, from
# when the model was baked into the image). A static cleanup policy (keep newest
# N, drop by age) cannot see what is deployed, so this is a scheduled Cloud Build
# that computes the referenced set and deletes the complement.
#
# An image is KEPT when any of these points at it:
#   * a Cloud Run service revision in DEV or PRD, any region, serving or not.
#     A revision keeps its image for as long as the revision exists; delete the
#     revision and the image becomes deletable on the next run.
#   * a Cloud Run job in DEV or PRD (the taxonomy jobs pin commit-SHA tags).
#   * the `latest` tag. Vertex AI training jobs (demand, supply, horizon) submit
#     `<package>:latest` on every run and nothing else records that reference.
# Everything else is DELETED once it is older than 7 days. Machine paths only
# need minutes (build push -> deploy pin); the week is margin for a person who
# deleted a revision and wants its image back.
#
# Scope: the docker-images and cloud-run-source-deploy repos in DEV and PRD.
# gae-flexible and gcf-artifacts are consumed by App Engine and Cloud Functions,
# which this does not enumerate, so they are left alone.
#
# Safety: the run ABORTS, deleting nothing, if any revision, job or image
# listing fails or if the referenced set is empty. An empty set would otherwise
# delete every image. var.artifact_registry_cleanup_dry_run (default true)
# logs the deletion list without deleting; flip it to false once a dry run has
# been read. Every run is a Cloud Build in OPS; the log is the audit trail.
#
# Runs as the Terraform SA (rsr-ds-group-ops-d0b0@appspot.gserviceaccount.com),
# which already holds roles/artifactregistry.admin in DEV and PRD. Bootstrap by
# hand before the first run, like its other cross-project roles:
#   * roles/run.viewer in DEV and PRD (list revisions and jobs)
#   * roles/cloudbuild.builds.editor in OPS and roles/iam.serviceAccountUser on
#     itself, so the scheduler's OAuth call may start a build that runs as it.

variable "artifact_registry_cleanup_dry_run" {
  description = "true: log what would be deleted and delete nothing. Set false after reading a dry-run log."
  type        = bool
  default     = true
}

locals {
  ar_cleanup = {
    project_ops = "rsr-ds-group-ops-d0b0"
    region      = "us-east1"
    projects    = ["rsr-ds-group-dev-f193", "rsr-ds-group-prd-83ad"]
    repos       = ["docker-images", "cloud-run-source-deploy"]
    min_age_h   = 168 # 7 days: machine paths need minutes; this is margin for a person to undo a deleted revision
    runtime_sa  = "rsr-ds-group-ops-d0b0@appspot.gserviceaccount.com"
  }
}

resource "google_cloudbuild_trigger" "artifact_registry_cleanup" {
  project     = local.ar_cleanup.project_ops
  name        = "artifact-registry-cleanup"
  location    = "global"
  description = "Delete container images no Cloud Run revision/job or latest tag references (older than ${local.ar_cleanup.min_age_h}h). Weekly via Cloud Scheduler; run by hand for an immediate pass."

  # Manual trigger: no repo, no event. Fired by Cloud Scheduler below or from the console.
  source_to_build {
    uri       = "https://github.com/randstadrisesmart/rsr-ds-gcp"
    ref       = "refs/heads/ops"
    repo_type = "GITHUB"
  }

  service_account = "projects/${local.ar_cleanup.project_ops}/serviceAccounts/${local.ar_cleanup.runtime_sa}"

  substitutions = {
    _DRY_RUN   = tostring(var.artifact_registry_cleanup_dry_run)
    _PROJECTS  = join(" ", local.ar_cleanup.projects)
    _REPOS     = join(" ", local.ar_cleanup.repos)
    _MIN_AGE_H = tostring(local.ar_cleanup.min_age_h)
  }

  build {
    options {
      logging = "CLOUD_LOGGING_ONLY"
    }
    timeout = "3600s"

    step {
      id         = "cleanup"
      name       = "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
      entrypoint = "bash"
      env = [
        "DRY_RUN=$_DRY_RUN",
        "PROJECTS=$_PROJECTS",
        "REPOS=$_REPOS",
        "MIN_AGE_H=$_MIN_AGE_H",
      ]
      # The trigger clones the ops branch, so the script runs from the checkout
      # (inlining it via file() would expose every `$` in it to Cloud Build's
      # substitution pass).
      args = ["environments/ops/artifact-registry-cleanup.sh"]
    }
  }
}

# Weekly, Monday 03:00 UTC, before the working day in Europe.
resource "google_cloud_scheduler_job" "artifact_registry_cleanup" {
  project          = local.ar_cleanup.project_ops
  region           = local.ar_cleanup.region
  name             = "artifact-registry-cleanup-weekly"
  description      = "Run the artifact-registry-cleanup Cloud Build trigger"
  schedule         = "0 3 * * 1"
  time_zone        = "Etc/UTC"
  attempt_deadline = "180s" # only starts the build

  http_target {
    http_method = "POST"
    uri         = "https://cloudbuild.googleapis.com/v1/projects/${local.ar_cleanup.project_ops}/locations/global/triggers/${google_cloudbuild_trigger.artifact_registry_cleanup.trigger_id}:run"
    body        = base64encode(jsonencode({ source = { branchName = "ops" } }))
    headers = {
      "Content-Type" = "application/json"
    }

    oauth_token {
      service_account_email = local.ar_cleanup.runtime_sa
    }
  }
}
