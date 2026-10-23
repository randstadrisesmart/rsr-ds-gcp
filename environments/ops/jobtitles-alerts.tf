# jobtitles: run-failed alerting
#
# The jobs themselves (daily normalisation, suggestion drain, backfill) are
# deployed by rsr-ds-taxonomy-wrapper's jobtitles/deploy/*.yaml. What lives here
# is the alert the CI/CD pipeline cannot create from inside the service repo: a
# log-based policy per environment that emails when a run of any of those jobs
# fails.
#
# A failed run logs "Normalization run failed" at ERROR and exits 1 (main.py,
# since rsr-ds-taxonomy-wrapper#113: it used to log a fatal error and exit 0, so
# a run that could not read its source passed as succeeded). Cloud Run's own
# errors for these jobs (a task killed at its timeout, a container that could
# not start) are caught by the system-log clause.
#
# Same project layout and Terraform roles as api-activity-monitoring.tf.

data "google_project" "jobtitles_alerts" {
  for_each   = { dev = "rsr-ds-group-dev-f193", prd = "rsr-ds-group-prd-83ad" }
  project_id = each.value
}

locals {
  jobtitles_alerts = { for env, p in data.google_project.jobtitles_alerts : env => p.project_id }
  jobtitles_jobs = [
    "taxonomy-project-jobtitles-normalization",
    "taxonomy-project-jobtitles-suggestions",
    "taxonomy-project-jobtitles-backfill",
  ]
}

variable "jobtitles_alert_emails" {
  description = "Email addresses that receive the jobtitles run-failed alert (both environments)."
  type        = list(string)
  default = [
    "giuliano.giuliani@randstadsourceright.nl",
    "fabrizio.giuliani@randstadsourceright.nl",
  ]
}

resource "google_monitoring_notification_channel" "jobtitles_email" {
  for_each = { for pair in setproduct(keys(local.jobtitles_alerts), var.jobtitles_alert_emails) : "${pair[0]}--${pair[1]}" => { env = pair[0], email = pair[1] } }

  project      = local.jobtitles_alerts[each.value.env]
  display_name = "jobtitles ${each.value.email}"
  type         = "email"
  labels = {
    email_address = each.value.email
  }
}

resource "google_monitoring_alert_policy" "jobtitles_run_failed" {
  for_each = local.jobtitles_alerts

  project      = each.value
  display_name = "Job-title normalisation: run failed (${each.key})"
  combiner     = "OR"

  conditions {
    display_name = "A jobtitles job run failed"
    condition_matched_log {
      filter = <<-EOF
        resource.type="cloud_run_job"
        resource.labels.job_name=(${join(" OR ", [for j in local.jobtitles_jobs : "\"${j}\""])})
        severity>=ERROR
        (textPayload:"Normalization run failed" OR logName:"run.googleapis.com%2Fvarlog%2Fsystem")
      EOF
      label_extractors = {
        job       = "EXTRACT(resource.labels.job_name)"
        execution = "EXTRACT(labels.\"run.googleapis.com/execution_name\")"
      }
    }
  }

  notification_channels = [
    for k, ch in google_monitoring_notification_channel.jobtitles_email : ch.id if startswith(k, "${each.key}--")
  ]

  alert_strategy {
    notification_rate_limit {
      period = "3600s"
    }
    auto_close = "172800s" # 48 h: two daily runs without a repeat clears it
  }

  documentation {
    content   = "A job-title normalisation job failed in ${each.key}. Its runs, with the error of each failed task:\n\nSELECT job, execution, task_index, status, error, started_at, titles_written FROM `${each.value}.TAXONOMY_PROJECT_jobtitles.pipeline_runs` WHERE started_at > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 DAY) ORDER BY started_at DESC\n\nA failed run is resumable: running the job again picks up the titles not yet written.\n\nCode: https://github.com/randstadrisesmart/rsr-ds-taxonomy-wrapper/tree/main/jobtitles"
    mime_type = "text/markdown"
  }
}
