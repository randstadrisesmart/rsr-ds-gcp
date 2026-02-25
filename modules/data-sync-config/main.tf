# Per-region data sync config: dataset + tracked_tables VIEW + sync_log table
#
# The tracked_tables VIEW replaces the former Google Sheet external table.
# Scheduled queries (02_sync_clone_*.sql) read from it unchanged.

variable "project_id" {
  description = "OPS project ID"
  type        = string
  default     = "rsr-ds-group-ops-d0b0"
}

variable "dataset_id" {
  description = "Dataset name, e.g. sync_config_US"
  type        = string
}

variable "location" {
  description = "BQ dataset location, e.g. US, EU, us-east1"
  type        = string
}

variable "entries" {
  description = "List of sync entries for this region"
  type = list(object({
    service        = string
    src_project    = string
    dataset_name   = string
    table_name     = string
    sync_frequency = string
    region         = string
    enabled        = bool
  }))
  default = []
}

resource "google_bigquery_dataset" "sync_config" {
  project    = var.project_id
  dataset_id = var.dataset_id
  location   = var.location

  labels = {
    managed_by = "terraform"
    purpose    = "data-sync-config"
  }
}

locals {
  # Build STRUCT literals for each entry
  struct_literals = [
    for e in var.entries :
    "STRUCT('${e.service}' AS service, '${e.src_project}' AS src_project, '${e.dataset_name}' AS dataset_name, '${e.table_name}' AS table_name, '${e.sync_frequency}' AS sync_frequency, '${e.region}' AS region, ${e.enabled} AS enabled)"
  ]

  # When no entries, use a typed empty array so the VIEW schema is always consistent
  view_sql = length(var.entries) > 0 ? (
    "SELECT * FROM UNNEST([${join(",\n  ", local.struct_literals)}])"
    ) : (
    "SELECT * FROM UNNEST(ARRAY<STRUCT<service STRING, src_project STRING, dataset_name STRING, table_name STRING, sync_frequency STRING, region STRING, enabled BOOL>>[])"
  )
}

resource "google_bigquery_table" "tracked_tables" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.sync_config.dataset_id
  table_id   = "tracked_tables"

  view {
    query          = local.view_sql
    use_legacy_sql = false
  }

  deletion_protection = false
}

resource "google_bigquery_table" "sync_log" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.sync_config.dataset_id
  table_id   = "sync_log"

  schema = jsonencode([
    { name = "run_id", type = "STRING", mode = "NULLABLE" },
    { name = "run_timestamp", type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "service", type = "STRING", mode = "NULLABLE" },
    { name = "src_project", type = "STRING", mode = "NULLABLE" },
    { name = "dataset_name", type = "STRING", mode = "NULLABLE" },
    { name = "table_name", type = "STRING", mode = "NULLABLE" },
    { name = "sync_frequency", type = "STRING", mode = "NULLABLE" },
    { name = "region", type = "STRING", mode = "NULLABLE" },
    { name = "status", type = "STRING", mode = "NULLABLE" },
    { name = "message", type = "STRING", mode = "NULLABLE" },
  ])

  lifecycle {
    prevent_destroy = true
  }
}
