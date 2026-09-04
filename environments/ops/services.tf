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
#   ollama   — LLM backed services (ollama, cleanpii)
#   talent   — Talent Radar (taxonomy, digitaltwin)
#   analysis — Other analysis (qamonitoring, mrapipeline, etc.)
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
      build_secrets = ["hf-token"]
      sync_tables = []
    }
    cleanpii = {
      repo          = "rsr-ds-cleanpii"
      build_group   = "ollama"
      region        = "europe-west1"     # co-located with ollama for lower latency
      build_secrets = ["hf-token"]       # HuggingFace auth for model downloads
      sync_tables   = []
    }
    temporary-classifier = {
      repo        = "rsr-ds-temporary-classifier"
      build_group = "analysis"
      sync_tables = []
    }
    compensation = {
      # The live service. Renamed from
      # rsr-ds-compensation-model-and-market-rate-analysis-booster on 2026-09-03;
      # the Cloud Run service is `compensation` and the prd tag is compensation-vX.Y.Z.
      # rsr-ds-compensation-legacy and rsr-ds-compensation-model are archived.
      repo        = "rsr-ds-compensation"
      build_group = "analysis"
      region      = "europe-west1"       # matches deploy/*.yaml _REGION
      sync_tables = []                   # BQML models live in DEV; PROD.md lists what PRD still needs
    }
    api-activity-monitoring = {
      repo        = "rsr-ds-api-activity-monitoring"
      build_group = "analysis"
      region      = "europe-west1"       # moved from us-east1 on 2026-09-04; matches deploy/*.yaml _REGION
      # Its Cloud Scheduler jobs and run-failed alert policies (DEV + PRD) are in
      # api-activity-monitoring.tf; the endpoint registry is checks/ in the repo.
      sync_tables = []
    }
    skills = {
      repo        = "rsr-ds-skills"
      build_group = "analysis"
      region      = "europe-west1"
      sync_tables = []
    }
    sector = {
      repo        = "rsr-ds-sector"
      build_group = "analysis"
      region      = "europe-west1"
      sync_tables = []
    }
    gateway = {
      repo        = "rsr-ds-gateway"
      build_group = "analysis"
      region      = "europe-west1"
      # Serves the agent chat UI at /ui for testers, so it is a frontend
      # service: the deploy pipeline runs `gcloud run services update --iap`
      # after each deploy. The OAuth client is configured once in the console
      # (ONBOARDING 7) and testers need roles/iap.httpsResourceAccessor.
      iap         = true
      sync_tables = []
    }
    job-title-matcher = {
      repo        = "rsr-ds-job-title-matcher"
      build_group = "analysis"
      region      = "europe-west1"       # matches deploy/*.yaml _REGION
      sync_tables = []                   # no BQ tables; models/indices mounted from gs://rsr-ds-models at runtime
    }
    jobtitle-normalizer = {
      repo        = "rsr-ds-jobtitle-normalizer"
      build_group = "analysis"
      region      = "europe-west1"       # matches deploy/dev-build.yaml _REGION, and the
                                         # BigQuery dataset TAXONOMY_PROJECT_jobtitles is
                                         # regional there — a mismatch breaks every query
      # Deploys a Cloud Run JOB, not a service: no HTTP surface, triggered by
      # Cloud Scheduler daily at 11:00 UTC, and a full backlog pass measured
      # 10h25m against the 60-minute ceiling a service allows. deploy/dev-build.yaml
      # therefore runs `gcloud run jobs deploy`. Nothing here provisions Cloud Run,
      # so this entry needs no special handling for that.
      #
      # DEV only for now by request: the repo deliberately has no
      # deploy/prod-build.yaml, so the prd trigger this module creates has
      # nothing to run.
      sync_tables = []                   # tables live in DEV; nothing to clone to PRD yet
    }
    careerpath = {
      repo        = "rsr-ds-careerpath"
      build_group = "analysis"
      region      = "europe-west1"       # matches deploy/*.yaml _REGION
      # Serving artifact is a computed columnar blob, not a BQ table, so no sync.
      # Built offline by pipeline/ and baked into the image at build time from
      # gs://location_object/career-path-model.
      sync_tables = []
    }
    demand = {
      repo        = "rsr-ds-demand"
      build_group = "analysis"
      region      = "europe-west1"       # matches deploy/*.yaml _REGION and the BQ datasets
      # The /v1/demand API reads this cube directly, so PRD needs its own copy.
      # Rebuilt quarterly by the demand pipeline, hence weekly sync.
      sync_tables = [
        { dataset_name = "demand_model_reveliolabs", table_name = "demand_by_location", sync_frequency = "weekly", region = "europe-west1" },
      ]
    }
    supply = {
      repo        = "rsr-ds-supply"
      build_group = "analysis"
      region      = "europe-west1"       # matches deploy/*.yaml _REGION and the BQ datasets
      # The /v1/supply API reads this cube directly, so PRD needs its own copy.
      # Rebuilt quarterly by the supply pipeline, hence weekly sync.
      sync_tables = [
        { dataset_name = "supply_eu", table_name = "supply_by_location", sync_frequency = "weekly", region = "europe-west1" },
      ]
    }
    scarcity = {
      repo        = "rsr-ds-scarcity"
      build_group = "analysis"
      region      = "europe-west1"       # matches deploy/*.yaml _REGION and the BQ datasets
      # The /v1/scarcity API reads these two cubes directly, so PRD needs its own
      # copies. Rebuilt quarterly by the demand/supply pipelines, hence weekly sync.
      sync_tables = [
        { dataset_name = "supply_eu", table_name = "final_market_scarcity_table", sync_frequency = "weekly", region = "europe-west1" },
        { dataset_name = "demand_model_reveliolabs", table_name = "market_tightness_final", sync_frequency = "weekly", region = "europe-west1" },
      ]
    }
    location-matcher = {
      repo        = "rsr-ds-location-matcher"
      build_group = "analysis"
      region      = "us-central1"        # matches deploy/*.yaml _REGION and Vertex AI (Gemini) location
      sync_tables = [
        # Queried at runtime by app/matcher.py via load_country_mapping().
        # Only 256 rows and rarely changes, but PRD hard-fails without it.
        { dataset_name = "location_normalization_model_EU", table_name = "country_mapping_clean", sync_frequency = "weekly", region = "europe-west1" },
        # Fallback only — the reference snapshot is baked into the image at
        # build time from gs://location_object/data/. This exists so the
        # BigQuery fallback path in app/reference_data.py still works in PRD.
        # 3M rows / ~337MB, so clone once rather than on every run.
        { dataset_name = "location_normalization_model_EU", table_name = "universal_locations_reference_dataset_with_variance", sync_frequency = "once", region = "europe-west1" },
      ]
    }
    location-normalizer = {
      repo        = "rsr-ds-location-normalizer"
      build_group = "analysis"
      region      = "europe-west1"       # matches deploy/dev-build.yaml _REGION, and the
                                         # BigQuery dataset TAXONOMY_PROJECT_locations is
                                         # regional there — a mismatch breaks every query
      # Deploys a Cloud Run JOB, not a service: no HTTP surface, triggered by
      # Cloud Scheduler daily at 06:00 UTC, after this pipeline's own regional
      # refreshes (01:45/02:00/02:45) and cross-region copies (04:30/04:45).
      # deploy/dev-build.yaml therefore runs `gcloud run jobs deploy`. Nothing
      # here provisions Cloud Run, so this entry needs no special handling.
      #
      # Independent of jobtitle-normalizer despite the similar shape: its own
      # repo, image, Cloud Run job, schedule and BigQuery registries. The two
      # share only the svc-ai-platform@ runtime identity.
      #
      # DEV only for now: the repo deliberately has no deploy/prod-build.yaml,
      # so the prd trigger this module creates has nothing to run.
      sync_tables = []                   # tables live in DEV; nothing to clone to PRD yet
    }
  }
}
