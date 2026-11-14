# jobtitles-corrections: the daily schedule of the correction pass, DEV and PRD
#
# The job (`taxonomy-project-jobtitles-corrections`, a Cloud Run JOB) is deployed
# by rsr-ds-taxonomy-wrapper/jobtitles/deploy/dev-build.yaml on every merge and
# by prod-build.yaml on a release tag, from the same image as the normalisation
# jobs (tools/correction_pass/daily.py). Each run reviews the OET label of the
# next 100,000 most frequent titles not checked yet and applies the corrections
# it is sure about, within $50 of Vertex AI a day (the job enforces both caps,
# so a second execution on the same day cannot double the spend).
#
# 14:00 UTC: after the 12:00 normalisation, so the day's new titles are in.
#
# The job must exist before the first apply (the IAM member addresses it by
# name): merge the taxonomy-wrapper change first, and tag a release for PRD.
# The Terraform SA needs roles/run.admin on the job and roles/cloudscheduler.admin
# in each project, granted by hand as for jobtitles-retrain.tf if missing.

locals {
  jobtitles_corrections = {
    dev = {
      project    = "rsr-ds-group-dev-f193"
      runtime_sa = "svc-ai-platform@rsr-ds-group-dev-f193.iam.gserviceaccount.com"
    }
    prd = {
      project    = "rsr-ds-group-prd-83ad"
      runtime_sa = "svc-ai-platform@rsr-ds-group-prd-83ad.iam.gserviceaccount.com"
    }
  }
  jobtitles_corrections_job    = "taxonomy-project-jobtitles-corrections"
  jobtitles_corrections_region = "europe-west1" # matches jobtitles/deploy/*-build.yaml _REGION
}

# The scheduler calls the Cloud Run Admin API as the job's own runtime account.
resource "google_cloud_run_v2_job_iam_member" "jobtitles_corrections_scheduler" {
  for_each = local.jobtitles_corrections

  project  = each.value.project
  location = local.jobtitles_corrections_region
  name     = local.jobtitles_corrections_job
  role     = "roles/run.invoker" # run.jobs.run
  member   = "serviceAccount:${each.value.runtime_sa}"
}

resource "google_cloud_scheduler_job" "jobtitles_corrections_daily" {
  for_each = local.jobtitles_corrections

  project          = each.value.project
  region           = local.jobtitles_corrections_region
  name             = local.jobtitles_corrections_job
  description      = "Daily correction pass: next 100k most frequent unchecked titles, $50/day cap"
  schedule         = "0 14 * * *"
  time_zone        = "Etc/UTC"
  attempt_deadline = "180s" # this only STARTS the execution; the run itself takes hours

  # No retry_config block: no retries is the API default (see jobtitles-retrain.tf).

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${each.value.project}/locations/${local.jobtitles_corrections_region}/jobs/${local.jobtitles_corrections_job}:run"
    body        = base64encode("{}")
    headers = {
      "Content-Type" = "application/json"
    }

    oauth_token {
      service_account_email = each.value.runtime_sa
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.jobtitles_corrections_scheduler]
}
