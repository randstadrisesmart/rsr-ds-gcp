# Service registry — edit this file to add/remove services and sync tables.
#
# Each service needs:
#   repo        — GitHub repo name under randstadrisesmart/
#   region      — (optional, default "us-east1") Cloud Run / AR region for triggers
#                 GPU (nvidia-l4) regions: europe-west1, us-central1, us-east4, etc.
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
      repo        = "rsr-ds-ollama"
      region      = "europe-west1"       # GPU (nvidia-l4) availability
      sync_tables = []
    }
  }
}
