# Resources that exist in GCP and are adopted into state on the next apply.
# Terraform 1.5+ import blocks: each one is a no-op once the resource is in
# state, so they can stay until the apply has run and then be deleted.
#
# The five rsr-ds-taxonomy-wrapper triggers were created by hand in 2026-09 when
# the two normaliser repos became one. Listed 2026-10-08 from the ops project:
#   taxonomy-wrapper-jobtitles-pr    cba6f420-4819-4996-9071-53ab69dbaa74
#   taxonomy-wrapper-jobtitles-dev   95f64682-f57a-49d0-9603-093e7ed9622d
#   taxonomy-wrapper-locations-pr    a6eb6c0d-4c4b-4887-81a2-720401a6b721
#   taxonomy-wrapper-locations-dev   ba21c64b-5cee-431f-80de-be781f687704
#   taxonomy-wrapper-api-pr          96294a4c-8a35-4c8a-88e0-249834f7d482
# The plan should show them as imported with an in-place update (the module
# adds the standard substitutions to the dev triggers), the prd and api-dev
# triggers as created disabled, and the six *-normalizer-* triggers destroyed.

import {
  to = module.cloud_build_trigger["taxonomy-wrapper-jobtitles"].google_cloudbuild_trigger.pr
  id = "projects/rsr-ds-group-ops-d0b0/locations/global/triggers/cba6f420-4819-4996-9071-53ab69dbaa74"
}

import {
  to = module.cloud_build_trigger["taxonomy-wrapper-jobtitles"].google_cloudbuild_trigger.dev
  id = "projects/rsr-ds-group-ops-d0b0/locations/global/triggers/95f64682-f57a-49d0-9603-093e7ed9622d"
}

import {
  to = module.cloud_build_trigger["taxonomy-wrapper-locations"].google_cloudbuild_trigger.pr
  id = "projects/rsr-ds-group-ops-d0b0/locations/global/triggers/a6eb6c0d-4c4b-4887-81a2-720401a6b721"
}

import {
  to = module.cloud_build_trigger["taxonomy-wrapper-locations"].google_cloudbuild_trigger.dev
  id = "projects/rsr-ds-group-ops-d0b0/locations/global/triggers/ba21c64b-5cee-431f-80de-be781f687704"
}

import {
  to = module.cloud_build_trigger["taxonomy-wrapper-api"].google_cloudbuild_trigger.pr
  id = "projects/rsr-ds-group-ops-d0b0/locations/global/triggers/96294a4c-8a35-4c8a-88e0-249834f7d482"
}
