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
#   iap           — (optional, default false) enable IAP on the Cloud Run service
#                   for frontend/UI services that users access in a browser
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
    rascoeditorllm = {
      repo        = "rsr-ds-rascoeditorllm"
      build_group = "ollama"
      region      = "europe-west1"       # GPU (nvidia-l4) availability
      sync_tables = []
    }
    job-title-matcher = {
      repo        = "rsr-ds-job-title-matcher"
      build_group = "ollama"
      region      = "europe-west1"       # co-located with rascoeditorllm
      sync_tables = []
    }
    rasco-taxonomy-editor = {
      repo        = "rsr-ds-rasco-taxonomy-editor"
      build_group = "ollama"
      iap         = true
      sync_tables = [
        { dataset_name = "rasco_taxonomy_fixes_US", table_name = "rasco_taxonomy", sync_frequency = "daily", region = "us-east1" },
        { dataset_name = "rasco_taxonomy_fixes_US", table_name = "job_title_input", sync_frequency = "once", region = "us-east1" },
        { dataset_name = "rasco_taxonomy_fixes_US", table_name = "job_title_results", sync_frequency = "once", region = "us-east1" },
        { dataset_name = "rasco_taxonomy_fixes_US", table_name = "processing_jobs", sync_frequency = "once", region = "us-east1" },
        { dataset_name = "rasco_taxonomy_fixes_US", table_name = "rasco_fixer_output_integration", sync_frequency = "once", region = "us-east1" },
      ]
    }
    sociallistening = {
      repo          = "rsr-ds-sociallistening"
      build_group   = "analysis"
      region        = "europe-west1"
      build_secrets = ["es-api-key", "hashstore-json", "encryptstore-json"]
      sync_tables   = [
        { dataset_name = "financial_data", table_name = "eod_quarterly_financial_reports", sync_frequency = "daily", region = "US" },
        { dataset_name = "financial_data", table_name = "eod_financial_news", sync_frequency = "daily", region = "US" },
        { dataset_name = "webscrapers", table_name = "indeed_us_company_names", sync_frequency = "weekly", region = "us-east1" },
        { dataset_name = "webscrapers", table_name = "glassdoor_dot_com_company_ratings_new", sync_frequency = "weekly", region = "us-east1" },
        { dataset_name = "webscrapers", table_name = "brandwatch_company_reviews", sync_frequency = "daily", region = "us-east1" },
      ]
    }
    temporary-classifier = {
      repo        = "rsr-ds-temporary-classifier"
      build_group = "analysis"
      sync_tables = []
    }
    compensation = {
      repo        = "rsr-ds-compensation"
      build_group = "analysis"
      sync_tables = []
    }
    dynamic-insights = {
      repo        = "rsr-ds-dynamic-insights"
      build_group = "talent"
      sync_tables = [
        { dataset_name = "webscrapers", table_name = "brandwatch_company_reviews", sync_frequency = "daily", region = "us-east1" },
        { dataset_name = "webscrapers", table_name = "talent_dot_com_taxation_data", sync_frequency = "weekly", region = "us-east1" },
        { dataset_name = "webscrapers", table_name = "numbeo_dot_com_cost_of_living", sync_frequency = "weekly", region = "us-east1" },
        { dataset_name = "webscrapers", table_name = "numbeo_dot_com_quality_of_life", sync_frequency = "weekly", region = "us-east1" },
        { dataset_name = "webscrapers", table_name = "indeed_us_company_names", sync_frequency = "weekly", region = "us-east1" },
        { dataset_name = "webscrapers", table_name = "glassdoor_dot_com_company_ratings_new", sync_frequency = "weekly", region = "us-east1" },
        { dataset_name = "financial_data", table_name = "eod_quarterly_financial_reports", sync_frequency = "daily", region = "US" },
        { dataset_name = "financial_data", table_name = "eod_macro_indicators", sync_frequency = "daily", region = "US" },
        { dataset_name = "testdataset", table_name = "bgdata", sync_frequency = "once", region = "US" },
      ]
    }
  }
}

