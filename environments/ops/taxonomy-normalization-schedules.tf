# taxonomy-normalization: the daily schedules of the job-title and location
# normalisation jobs, DEV and PRD
#
# The jobs (`taxonomy-project-jobtitles-normalization` and
# `taxonomy-project-locations-normalization`, Cloud Run JOBS) are deployed by
# rsr-ds-taxonomy-wrapper's jobtitles/ and locations/ deploy/*-build.yaml. Their
# schedulers were created by hand with gcloud when the two normaliser repos
# became one; the import blocks below adopt them into state as they are, so the
# first apply changes nothing but the DEV job-title description (it still said
# 05:00 UTC). The import blocks are no-ops once applied and can then be deleted.
#
# 12:00 job titles, 12:30 locations: after the regional refreshes and the
# cross-region copies of the morning. Both runs are idempotent and resumable
# (they process only values not normalised yet), so a missed day is caught up
# by the next.
#
# The scheduler calls the Cloud Run Admin API (v1 :run) as the project's
# svc-ai-platform account, which already holds run.jobs.run on them; no IAM is
# managed here. The retry_config is the one the API gave these jobs when they
# were created (no retries, its default backoff), written out because the API
# echoes it back: without it every plan would show it being removed.

locals {
  taxonomy_normalization_region = "europe-west1"
  taxonomy_normalization_projects = {
    dev = "rsr-ds-group-dev-f193"
    prd = "rsr-ds-group-prd-83ad"
  }
  taxonomy_normalization_jobs = {
    jobtitles = {
      schedule    = "0 12 * * *"
      description = "Runs the centralised job-title normalization, 12:00 UTC. Idempotent and resumable: processes only titles absent from job_titles_normalised."
    }
    locations = {
      schedule    = "30 12 * * *"
      description = "Drain the pending location backlog, 12:30 UTC, after the regional refreshes and the cross-region copies."
    }
  }
  # one entry per scheduler: "<env>-<kind>"
  taxonomy_normalization_schedules = {
    for pair in setproduct(keys(local.taxonomy_normalization_projects), keys(local.taxonomy_normalization_jobs)) :
    "${pair[0]}-${pair[1]}" => {
      project     = local.taxonomy_normalization_projects[pair[0]]
      job         = "taxonomy-project-${pair[1]}-normalization"
      schedule    = local.taxonomy_normalization_jobs[pair[1]].schedule
      description = local.taxonomy_normalization_jobs[pair[1]].description
    }
  }
}

import {
  for_each = local.taxonomy_normalization_schedules
  to       = google_cloud_scheduler_job.taxonomy_normalization[each.key]
  id       = "projects/${each.value.project}/locations/${local.taxonomy_normalization_region}/jobs/${each.value.job}"
}

resource "google_cloud_scheduler_job" "taxonomy_normalization" {
  for_each = local.taxonomy_normalization_schedules

  project          = each.value.project
  region           = local.taxonomy_normalization_region
  name             = each.value.job
  description      = each.value.description
  schedule         = each.value.schedule
  time_zone        = "UTC"
  attempt_deadline = "180s" # this only STARTS the execution; the run itself takes minutes

  retry_config {
    retry_count          = 0
    max_retry_duration   = "0s"
    min_backoff_duration = "5s"
    max_backoff_duration = "3600s"
    max_doublings        = 5
  }

  http_target {
    http_method = "POST"
    uri         = "https://europe-west1-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${each.value.project}/jobs/${each.value.job}:run"

    oauth_token {
      service_account_email = "svc-ai-platform@${each.value.project}.iam.gserviceaccount.com"
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }
}
