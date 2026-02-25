# Service registry — edit this file to add/remove services and sync tables.
#
# Each service needs a repo name. Add sync_tables to declare BQ tables
# that should be zero-copy cloned DEV → PRD by the nightly scheduled queries.

locals {
  services = {
    test-iap-api = {
      repo        = "rsr-ds-test-iap-api"
      sync_tables = []
    }
  }
}
