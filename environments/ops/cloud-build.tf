# Per-service Cloud Build triggers + build SAs
#
# Add a new service: add a row to local.services, terraform apply.

locals {
  services = {
    test-iap-api     = { repo = "rsr-ds-test-iap-api" }
  }
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
