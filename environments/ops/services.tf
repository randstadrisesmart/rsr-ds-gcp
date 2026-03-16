# Service registry — edit this file to add/remove services and sync tables.
#
# Each service needs:
#   repo          — GitHub repo name under randstadrisesmart/
#   build_group   — shared build SA group name (services in the same group share
#                   one SA: svc-build-{group}@ops). IAM is requested once per group.
#   region        — (optional, default "us-east1") Cloud Run / AR region for triggers
#                   GPU (nvidia-l4) regions: europe-west1, us-central1, us-east4, etc.
#   build_secrets — (optional, default []) list of OPS Secret Manager secret IDs
#                   that the build SA needs access to at build time
#   sync_tables   — list of BQ tables to zero-copy clone DEV → PRD nightly
#                   use sync_tables = [] if the service has no BQ tables
#
# Build groups:
#   ollama   — LLM backed services (ollama, cleanpii, rascoeditorllm)
#   talent   — Talent Radar (taxonomy, digitaltwin)
#   analysis — Other analysis (sociallistening, qamonitoring, mrapipeline, etc.)
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
      build_group = "test-iap-api"
      sync_tables = [
        { dataset_name = "test_iap_api", table_name = "smoke_test", sync_frequency = "once", region = "us-east1" },
      ]
    }
    ollama = {
      repo        = "rsr-ds-ollama"
      build_group = "ollama"
      region      = "europe-west1"       # GPU (nvidia-l4) availability
      sync_tables = []
    }
    cleanpii = {
      repo          = "rsr-ds-cleanpii"
      build_group   = "ollama"
      region        = "europe-west1"     # co-located with ollama for lower latency
      build_secrets = ["hf-token"]       # HuggingFace auth for model downloads
      sync_tables   = []
    }
  }

  # Unique build groups — one SA per group
  build_groups = toset([for svc in local.services : svc.build_group])

  # Unique (build_group, secret) pairs for build-time secret access
  build_secret_grants = { for pair in distinct(flatten([
    for svc_name, svc in local.services : [
      for secret in lookup(svc, "build_secrets", []) : {
        key         = "${svc.build_group}--${secret}"
        build_group = svc.build_group
        secret_id   = secret
      }
    ]
  ])) : pair.key => pair }
}
