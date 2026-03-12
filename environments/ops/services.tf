# Service registry — edit this file to add/remove services and sync tables.
#
# Each service needs:
#   repo        — GitHub repo name under randstadrisesmart/
#   sync_tables — list of BQ tables to zero-copy clone DEV → PRD nightly
#                 use sync_tables = [] if the service has no BQ tables
#
# sync_tables fields:
#   dataset_name   — BQ dataset name (same in DEV and PRD)
#   table_name     — BQ table name
#   sync_frequency — how often to clone:
#                      "once"    — clone only if table doesn't exist in PRD (initial migration)
#                      "daily"   — clone on every run
#                      "weekly"  — clone on Mondays (or if table doesn't exist)
#                      "monthly" — clone on the 1st of the month (or if table doesn't exist)
#   region         — BQ location: "US", "EU", "us-east1", "europe-west1", "australia-southeast1"
#   enabled        — (optional, default true) set to false to pause sync

locals {
  services = {
    test-iap-api = {
      repo        = "rsr-ds-test-iap-api"
      sync_tables = [
        { dataset_name = "test_iap_api", table_name = "smoke_test", sync_frequency = "once", region = "us-east1" },
      ]
    }
    ollama = {
      repo = "rsr-ds-ollama"
      sync_tables = []
    }
  }
}
