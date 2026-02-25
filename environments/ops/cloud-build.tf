# Per-service Cloud Build triggers + build SAs + data sync config
#
# Add a new service: add a row to local.services (with optional sync_tables),
# terraform apply. The sync_tables entries drive the tracked_tables VIEWs
# that the nightly BQ Scheduled Queries read from.

locals {
  services = {
    test-iap-api = {
      repo        = "rsr-ds-test-iap-api"
      sync_tables = []
    }
  }

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

# Create per-service build SAs
module "build_sa" {
  for_each     = local.services
  source       = "../../modules/build-service-account"
  service_name = each.key
}

# Create per-service Cloud Build triggers
module "cloud_build_trigger" {
  for_each     = local.services
  source       = "../../modules/cloud-build-trigger"
  service_name = each.key
  github_repo  = each.value.repo
  build_sa     = module.build_sa[each.key].build_sa_email
}
