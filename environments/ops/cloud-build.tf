# Per-service Cloud Build triggers + build SAs

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
  region       = lookup(each.value, "region", "us-east1")
}
