# api-activity-monitoring: schedule + alerting
#
# The service itself is deployed by its repo's deploy/*.yaml like every other service
# (registered in services.tf). What lives here is everything the CI/CD pipeline cannot
# create from inside a service repo:
#
#   * the Cloud Scheduler job that invokes it in DEV and PRD, and
#   * a log-based alert policy per environment that fires when a run reports failures.
#
# The service returns HTTP 500 when any check fails, so the scheduler records the run as
# failed. Retries are off on purpose: a run already retries transient outcomes per check,
# and re-running a 15-minute sweep would not change a 404.
#
# The hand-made jobs (created 2026-05, timezone Africa/Conakry, hourly) share this name.
# Delete them before the first apply so Terraform creates the jobs from this definition
# and the state has a clean origin (alternative: terraform import, but that leaves the
# hand-made history in place):
#   gcloud scheduler jobs delete api_activity_monitoring --location=us-east1 --project=rsr-ds-group-dev-f193
#   gcloud scheduler jobs delete api_activity_monitoring --location=us-east1 --project=rsr-ds-group-prd-83ad
#
# The Terraform SA needs roles/cloudscheduler.admin and roles/monitoring.alertPolicyEditor
# (plus roles/monitoring.notificationChannelEditor if channels are set) in DEV and PRD.

locals {
  api_activity_monitoring = {
    dev = {
      project        = "rsr-ds-group-dev-f193"
      project_number = "598511938992"
    }
    prd = {
      project        = "rsr-ds-group-prd-83ad"
      project_number = "950407139876"
    }
  }
  api_activity_monitoring_region  = "us-east1"
  api_activity_monitoring_service = "api-activity-monitoring"
}

variable "api_activity_monitoring_alert_emails" {
  description = "Email addresses that receive the api-activity-monitoring run-failed alert (both environments)."
  type        = list(string)
  default     = ["wayne.kenney@randstadsourceright.com"]
}

resource "google_cloud_scheduler_job" "api_activity_monitoring" {
  for_each = local.api_activity_monitoring

  project          = each.value.project
  region           = local.api_activity_monitoring_region
  name             = "api_activity_monitoring" # matches the hand-made job so it can be imported
  description      = "Run the API activity monitor (${each.key}) once a day"
  schedule         = "0 6 * * *"
  time_zone        = "Etc/UTC"
  attempt_deadline = "1800s" # equals the Cloud Run request timeout

  retry_config {
    retry_count = 0
  }

  http_target {
    http_method = "POST"
    uri         = "https://${local.api_activity_monitoring_service}-${each.value.project_number}.${local.api_activity_monitoring_region}.run.app/"
    body        = base64encode("{}")
    headers = {
      "Content-Type" = "application/json"
    }

    oidc_token {
      service_account_email = "svc-ai-platform@${each.value.project}.iam.gserviceaccount.com"
      audience              = "https://${local.api_activity_monitoring_service}-${each.value.project_number}.${local.api_activity_monitoring_region}.run.app"
    }
  }
}

resource "google_monitoring_notification_channel" "api_activity_monitoring_email" {
  for_each = { for pair in setproduct(keys(local.api_activity_monitoring), var.api_activity_monitoring_alert_emails) : "${pair[0]}--${pair[1]}" => { env = pair[0], email = pair[1] } }

  project      = local.api_activity_monitoring[each.value.env].project
  display_name = "api-activity-monitoring ${each.value.email}"
  type         = "email"
  labels = {
    email_address = each.value.email
  }
}

resource "google_monitoring_alert_policy" "api_activity_monitoring_run_failed" {
  for_each = local.api_activity_monitoring

  project      = each.value.project
  display_name = "API activity monitoring: run failed (${each.key})"
  combiner     = "OR"

  conditions {
    display_name = "A monitoring run reported failed checks or crashed"
    condition_matched_log {
      filter = <<-EOF
        resource.type="cloud_run_revision"
        resource.labels.service_name="${local.api_activity_monitoring_service}"
        severity>=ERROR
        (jsonPayload.event="run_failed" OR jsonPayload.event="run_crashed")
      EOF
      label_extractors = {
        failed = "EXTRACT(jsonPayload.failed)"
        total  = "EXTRACT(jsonPayload.total)"
      }
    }
  }

  notification_channels = [
    for k, ch in google_monitoring_notification_channel.api_activity_monitoring_email : ch.id if startswith(k, "${each.key}--")
  ]

  alert_strategy {
    notification_rate_limit {
      period = "3600s"
    }
    auto_close = "172800s" # 48 h: two daily runs without a repeat clears it
  }

  documentation {
    content   = "One or more registered endpoints failed in ${each.key}. Query the run:\n\nSELECT api_name, endpoint, status_code, response FROM `${each.value.project}.API_activity_monitoring.api_execution_logs` WHERE test_status='FAIL' AND execution_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 HOUR)\n\nRegistry: https://github.com/randstadrisesmart/rsr-ds-api-activity-monitoring/tree/main/checks"
    mime_type = "text/markdown"
  }
}
