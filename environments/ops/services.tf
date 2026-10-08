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
#   path          — (optional) subfolder of a monorepo that holds this component;
#                   its configs are <path>/deploy/*.yaml. Triggers are named after
#                   the registry key, and the key is the _SERVICE_NAME the build gets.
#   comment_control — (optional, default false) PR builds wait for "/gcbrun"
#   dev_enabled / prd_enabled — (optional, default true) false keeps that trigger
#                   disabled (a component without that deploy config)
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
      region      = "europe-west1"
      sync_tables = [
        { dataset_name = "test_iap_api", table_name = "smoke_test", sync_frequency = "once", region = "us-east1" },
      ]
    }
    ollama = {
      repo          = "rsr-ds-ollama"
      build_group   = "ollama"
      region        = "europe-west1" # GPU (nvidia-l4) availability
      build_secrets = ["hf-token"]
      sync_tables   = []
    }
    cleanpii = {
      repo          = "rsr-ds-cleanpii"
      build_group   = "ollama"
      region        = "europe-west1" # co-located with ollama for lower latency
      build_secrets = ["hf-token"]   # HuggingFace auth for model downloads
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
      region      = "europe-west1" # matches deploy/*.yaml _REGION
      sync_tables = []             # BQML models live in DEV; PROD.md lists what PRD still needs
    }
    api-activity-monitoring = {
      repo        = "rsr-ds-api-activity-monitoring"
      build_group = "analysis"
      region      = "europe-west1" # moved from us-east1 on 2026-09-04; matches deploy/*.yaml _REGION
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
      region      = "europe-west1" # matches deploy/*.yaml _REGION
      sync_tables = []             # no BQ tables; models/indices mounted from gs://rsr-ds-models at runtime
    }
    # ── rsr-ds-taxonomy-wrapper: one repo, three components ──
    # jobtitles/ and locations/ were the repos rsr-ds-jobtitle-normalizer and
    # rsr-ds-location-normalizer until 2026-09; those repos are gone and the
    # triggers that pointed at them are removed with their registry entries.
    # The monorepo's triggers were created by hand on 2026-09-26/28 with
    # comment control on (PR builds wait for "/gcbrun"); registered here as they
    # are and imported (imports.tf), so this apply changes nothing that fires.
    # Deploys are Cloud Run JOBS (jobtitles, locations) deployed by their own
    # dev-build.yaml; the API is deployed by hand in a fixed order (its README),
    # so it has a PR check only. No prod configs yet: prd triggers disabled.
    taxonomy-wrapper-jobtitles = {
      repo            = "rsr-ds-taxonomy-wrapper"
      path            = "jobtitles"
      build_group     = "analysis"
      region          = "europe-west1" # the BigQuery datasets are regional there
      comment_control = true
      prd_enabled     = false
      sync_tables     = []
    }
    taxonomy-wrapper-locations = {
      repo            = "rsr-ds-taxonomy-wrapper"
      path            = "locations"
      build_group     = "analysis"
      region          = "europe-west1"
      comment_control = true
      prd_enabled     = false
      sync_tables     = []
    }
    taxonomy-wrapper-api = {
      repo            = "rsr-ds-taxonomy-wrapper"
      path            = "api"
      build_group     = "analysis"
      region          = "europe-west1"
      comment_control = true
      dev_enabled     = false
      prd_enabled     = false
      sync_tables     = []
    }
    careerpath = {
      repo        = "rsr-ds-careerpath"
      build_group = "analysis"
      region      = "europe-west1" # matches deploy/*.yaml _REGION
      # Serving artifact is a computed columnar blob, not a BQ table, so no sync.
      # Built offline by pipeline/ and baked into the image at build time from
      # gs://location_object/career-path-model.
      sync_tables = []
    }
    demand = {
      repo        = "rsr-ds-demand"
      build_group = "analysis"
      region      = "europe-west1" # matches deploy/*.yaml _REGION and the BQ datasets
      # The /v1/demand API reads this cube directly, so PRD needs its own copy.
      # Rebuilt quarterly by the demand pipeline, hence weekly sync.
      sync_tables = [
        { dataset_name = "demand_model_reveliolabs", table_name = "demand_by_location", sync_frequency = "weekly", region = "europe-west1" },
      ]
    }
    supply = {
      repo        = "rsr-ds-supply"
      build_group = "analysis"
      region      = "europe-west1" # matches deploy/*.yaml _REGION and the BQ datasets
      # The /v1/supply API reads this cube directly, so PRD needs its own copy.
      # Rebuilt quarterly by the supply pipeline, hence weekly sync.
      sync_tables = [
        { dataset_name = "supply_eu", table_name = "supply_by_location", sync_frequency = "weekly", region = "europe-west1" },
      ]
    }
    scarcity = {
      repo        = "rsr-ds-scarcity"
      build_group = "analysis"
      region      = "europe-west1" # matches deploy/*.yaml _REGION and the BQ datasets
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
      region      = "europe-west1" # matches deploy/*.yaml _REGION and the BQ datasets; Gemini is on `global`
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
  }
}
