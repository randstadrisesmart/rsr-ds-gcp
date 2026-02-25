# Data sync config — one module instance per BQ region
#
# Each creates a sync_config_* dataset with a tracked_tables VIEW
# (replacing the former Google Sheet external table) and a sync_log table.
# Entries come from local.all_sync_entries in cloud-build.tf.

module "sync_config_us" {
  source     = "../../modules/data-sync-config"
  dataset_id = "sync_config_US"
  location   = "US"
  entries    = [for e in local.all_sync_entries : e if e.region == "US"]
}

module "sync_config_eu" {
  source     = "../../modules/data-sync-config"
  dataset_id = "sync_config_EU"
  location   = "EU"
  entries    = [for e in local.all_sync_entries : e if e.region == "EU"]
}

module "sync_config_us_east1" {
  source     = "../../modules/data-sync-config"
  dataset_id = "sync_config_us_east1"
  location   = "us-east1"
  entries    = [for e in local.all_sync_entries : e if e.region == "us-east1"]
}

module "sync_config_europe_west1" {
  source     = "../../modules/data-sync-config"
  dataset_id = "sync_config_europe_west1"
  location   = "europe-west1"
  entries    = [for e in local.all_sync_entries : e if e.region == "europe-west1"]
}

module "sync_config_australia_southeast1" {
  source     = "../../modules/data-sync-config"
  dataset_id = "sync_config_australia_southeast1"
  location   = "australia-southeast1"
  entries    = [for e in local.all_sync_entries : e if e.region == "australia-southeast1"]
}
