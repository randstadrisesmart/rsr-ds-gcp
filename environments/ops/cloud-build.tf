# Per-group build SAs + per-service Cloud Build triggers

locals {
  # Flatten all sync_tables across services into a single list.
  # Each entry gets the service name and a hardcoded src_project.
  all_sync_entries = flatten([
    for svc_name, svc in local.services : [
      for t in lookup(svc, "sync_tables", []) : {
        service        = svc_name
        src_project    = "rsr-ds-group-dev-f193"
        dataset_name   = t.dataset_name
        table_name     = t.table_name
        sync_frequency = t.sync_frequency
        region         = t.region
        enabled        = lookup(t, "enabled", true)
      }
    ]
  ])
}

# Create one build SA per group (not per service)
module "build_sa" {
  for_each           = local.build_groups
  source             = "../../modules/build-service-account"
  service_name       = each.key
  build_status_topic = google_pubsub_topic.build_status.name
}

# Grant build SAs access to build-time secrets (e.g. hf-token)
resource "google_secret_manager_secret_iam_member" "build_secrets" {
  for_each  = local.build_secret_grants
  project   = "rsr-ds-group-ops-d0b0"
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${module.build_sa[each.value.build_group].build_sa_email}"
}

# Create per-service Cloud Build triggers (using the group's SA)
module "cloud_build_trigger" {
  for_each     = local.services
  source       = "../../modules/cloud-build-trigger"
  service_name = each.key
  github_repo  = each.value.repo
  build_sa     = module.build_sa[each.value.build_group].build_sa_email
  region       = lookup(each.value, "region", "us-east1")
}
