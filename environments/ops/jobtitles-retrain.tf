# jobtitles-retrain: who may run the retrain job, and the schedule that drains its queue
#
# The job itself (`taxonomy-project-jobtitles-retrain`, a Cloud Run JOB in DEV) is
# deployed by rsr-ds-taxonomy-wrapper/jobtitles/deploy/dev-build.yaml on every
# merge, like the two normalisation jobs beside it. What lives here is what that
# pipeline cannot create from inside the repo:
#
#   * the grant that lets named people execute the job with arguments
#     (`gcloud run jobs execute ... --args=release,--release,<id>`), and
#   * the Cloud Scheduler job that executes it with no arguments every hour,
#     so a row in TAXONOMY_PROJECT_jobtitles.retrain_requests is picked
#     up without anyone holding Cloud Run permissions (the image's default
#     command drains that queue and exits at once when it is empty).
#
# Executing with --args needs run.jobs.runWithOverrides, which roles/run.invoker
# does not carry; roles/run.developer on the ONE job resource does, and grants
# nothing on any other service or job. The scheduler needs only run.jobs.run.
#
# The job must exist before the first apply (the IAM resources address it by
# name): merge the taxonomy-wrapper change first. The Terraform SA needs
# roles/run.admin (for run.jobs.setIamPolicy) and roles/cloudscheduler.admin in DEV.
# Bootstrap, by hand, like its other DEV roles: on 2026-10-08 the first apply
# failed on run.jobs.getIamPolicy, and run.admin was granted to
# rsr-ds-group-ops-d0b0@appspot.gserviceaccount.com on this ONE job (not the
# project); the re-run then created the IAM members and the scheduler.
#
# DEV only: there is no PRD retrain. A model reaches PRD through the matcher's
# own tag release, which pins the staged folder in its prod-build.yaml.

locals {
  jobtitles_retrain = {
    project    = "rsr-ds-group-dev-f193"
    region     = "europe-west1" # matches jobtitles/deploy/dev-build.yaml _REGION
    job        = "taxonomy-project-jobtitles-retrain"
    runtime_sa = "svc-ai-platform@rsr-ds-group-dev-f193.iam.gserviceaccount.com"
  }
}

variable "jobtitles_retrain_operators" {
  description = "People who may execute the retrain job directly, with arguments. The queue (retrain_requests) has its own operator list in the job's config."
  type        = list(string)
  default = [
    "wayne.kenney@randstadsourceright.com",
    "giuliano.giuliani@randstadsourceright.nl",
  ]
}

resource "google_cloud_run_v2_job_iam_member" "jobtitles_retrain_operator" {
  for_each = toset(var.jobtitles_retrain_operators)

  project  = local.jobtitles_retrain.project
  location = local.jobtitles_retrain.region
  name     = local.jobtitles_retrain.job
  role     = "roles/run.developer" # run.jobs.run + run.jobs.runWithOverrides, on this job only
  member   = "user:${each.value}"
}

# The scheduler calls the Cloud Run Admin API as the job's own runtime account.
resource "google_cloud_run_v2_job_iam_member" "jobtitles_retrain_scheduler" {
  project  = local.jobtitles_retrain.project
  location = local.jobtitles_retrain.region
  name     = local.jobtitles_retrain.job
  role     = "roles/run.invoker" # run.jobs.run
  member   = "serviceAccount:${local.jobtitles_retrain.runtime_sa}"
}

# Staging writes gs://global-taxonomy-bucket/jobtitles/model/<taxonomy>/<release>/
# and the cleanup deletes old folders. The runtime account has had objectAdmin on
# that bucket since 2026-09-25 (granted by hand when the bucket was created, with
# the matcher's move there in its PR #13), so no grant is needed here. The
# objectAdmin on rsr-ds-models this file first carried (applied 2026-10-08) was
# for the bucket the matcher had already left; removed the same day.

resource "google_cloud_scheduler_job" "jobtitles_retrain_queue" {
  project          = local.jobtitles_retrain.project
  region           = local.jobtitles_retrain.region
  name             = "taxonomy-project-jobtitles-retrain-queue"
  description      = "Drain TAXONOMY_PROJECT_jobtitles.retrain_requests: execute the retrain job with no arguments"
  schedule         = "0 * * * *"
  time_zone        = "Etc/UTC"
  attempt_deadline = "180s" # this only STARTS the execution; the run itself may take hours

  # No retry_config block: no retries is the API default, and an explicit
  # all-zero block is not echoed back, so it showed as a change on every apply.

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${local.jobtitles_retrain.project}/locations/${local.jobtitles_retrain.region}/jobs/${local.jobtitles_retrain.job}:run"
    body        = base64encode("{}")
    headers = {
      "Content-Type" = "application/json"
    }

    oauth_token {
      service_account_email = local.jobtitles_retrain.runtime_sa
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.jobtitles_retrain_scheduler]
}
