# CI/CD Architecture & Environment Setup (RSR Pattern)

**Date:** 2026-02-18
**Project:** RSR Data Science Group
**Architecture:** Multi-Repo + GitHub + Cloud Build + Per-Service Build SAs
**Based on:** Randstad Enterprise Data Platform CI/CD patterns

---

## Table of Contents

1. [Environment Overview](#environment-overview)
3. [Repository Structure](#repository-structure)
4. [CI/CD Pipeline Flow](#cicd-pipeline-flow)
5. [Cloud Build Configuration](#cloud-build-configuration)
6. [BigQuery Data Strategy](#bigquery-data-strategy)
7. [Data Sync Pipeline](#data-sync-pipeline)
8. [IAM & Security](#iam--security)
9. [Service-to-Service Communication](#service-to-service-communication)
10. [Environment Configuration in Code](#environment-configuration-in-code)
11. [Ops Project Setup](#ops-project-setup)
12. [Migration Checklist](#migration-checklist)

---

## Reference Documentation

This document follows the Randstad standard CI/CD patterns documented in `./documentation/`:
- **CD Templates Usage.docx** — GitHub template repos, per-service build SAs, SSH deploy keys
- **Release Management - Configs.pptx** — Branch/tag naming, squash-and-merge, tag-driven prod releases
- **SCOPE+CICD+-+WIP.doc** — Cloud Build triggers, PubSub-driven promotion, image copy dev→prod

---

## Environment Overview

| Project | ID | Purpose | Data (Current) | Data (Target) | Deployment Trigger |
|---------|-----|---------|----------------|---------------|-------------------|
| **DEV** | `rsr-ds-group-dev-f193` | Development, experimentation, testing | **ALL production data lives here today** | Source of truth for data | Merge to `main` |
| **PRD** | `rsr-ds-group-prd-83ad` | Production workloads | Empty | Full copy (synced nightly from DEV) | Tag `v1.2.3` + manual approval |
| **OPS** | `rsr-ds-group-ops-d0b0` | Shared infrastructure, Cloud Build triggers | Logs, metrics, CI/CD state | Logs, metrics, CI/CD state, PubSub topics | N/A |

---

## Repository Structure

### GitHub Organization Layout

> **Sunset:** `rsr-ds-jobsearchsec` and `rsr-ds-jobenrichment` are **not being migrated**. Support ends Apr 23 2026. They remain as-is in DEV until deletion.

```
GitHub Organization: randstadrisesmart/
│
├── rsr-ds-digitaltwin/               # MEDIUM priority - 8K req/month
│   └── ...
│
├── rsr-ds-taxonomy/                  # MEDIUM priority - 18K req/month
│   └── ...
│
├── rsr-ds-sociallistening/           # LOW priority - 104 req/month
│   └── ...
│
├── rsr-ds-qamonitoring/              # LOW priority - internal tool
│   └── ...
│
├── rsr-ds-mrapipeline/               # LOW priority - 442 req/month
│   └── ...
│
├── rsr-ds-rascoeditorllm/            # HIGH priority - 358K req/month
│   └── ...
│
├── rsr-ds-ollama/                    # HIGH priority - 73K req/month
│   └── ...
│
├── rsr-ds-langapi/                   # MEDIUM priority - 18K req/month
│   └── ...
│
├── rsr-ds-vegas-normalization/       # LOW priority - 1.2K req/month
│   └── ...
│
├── rsr-ds-kaiser-sow/                # BATCH - daily
│   └── ...
│
├── rsr-ds-bluedata-normalization/    # BATCH - 6 regional instances
│   └── ...
│
├── rsr-ds-client-eda/                # BATCH - weekly
│   └── ...
│
├── rsr-ds-sourcing-capacity/         # LOW priority - 432 req/month
│   └── ...
│
└── rsr-ds-gcp/                       # Infrastructure as Code
    └── terraform/
        ├── modules/
        │   ├── cloud-run-service/
        │   ├── bigquery-dataset/
        │   ├── bq-dataset-copy/
        │   ├── bq-scheduled-sync/
        │   ├── cloud-build-trigger/
        │   └── iam-bindings/
        ├── environments/
        │   ├── dev/
        │   ├── prd/
        │   └── ops/
        └── .github/              # (optional) self-deploy via Cloud Build
```

### Repository Setup Checklist (per CD Templates)

For each new repo:
1. Create from a GitHub template repo (see `randstadrisesmart` template repos)
2. Generate 4096-bit SSH key pair for deploy key
3. Store private key in OPS Secret Manager as `ssh-deploy-key-{service-name}`
4. Configure deploy key on the GitHub repo (read-only)
5. Share repo with required groups + data engineering bot account
6. Configure branch protection rules (per `res-repo-common-repo-rules`)
7. Create Cloud Build triggers in OPS project (dev + prod)

### Naming Conventions (per Release Management)

| Item | Pattern | Example |
|------|---------|---------|
| Feature branch | `feature-{service}-{description}` | `feature-taxonomy-add-caching` |
| Tag (prod release) | `{service}-v{X.X.X}` | `taxonomy-v1.2.3` |
| Merge strategy | Squash and merge | Single commit on main per feature |

---

## CI/CD Pipeline Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              GitHub Repos                                    │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐       │
│  │rascoeditorllm│ │  taxonomy    │ │   ollama     │ │  langapi     │       │
│  └──────┬───────┘ └──────┬───────┘ └──────┬───────┘ └──────┬───────┘       │
└─────────┼────────────────┼────────────────┼────────────────┼────────────────┘
          │                │                │                │
          ▼                ▼                ▼                ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Cloud Build (OPS Project)                                  │
│                    rsr-ds-group-ops-d0b0                                      │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐     │
│  │  DEV TRIGGER (per service)                                          │     │
│  │  Event: push to main branch                                         │     │
│  │  SA: svc-build-{service}@ops                                        │     │
│  │  Config: deploy/dev-build.yaml                                      │     │
│  │                                                                     │     │
│  │  Steps:                                                             │     │
│  │    1. Clone repo (SSH deploy key from Secret Manager)               │     │
│  │    2. Run tests (pytest)                                            │     │
│  │    3. Build Docker image                                            │     │
│  │    4. Push to DEV Artifact Registry                                 │     │
│  │    5. Deploy to DEV Cloud Run                                       │     │
│  │    6. Publish success to PubSub topic                               │     │
│  └────────────────────────────────┬────────────────────────────────────┘     │
│                                   │                                          │
│                                   ▼ (PubSub: pipelines_build_status)         │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐     │
│  │  PROD TRIGGER (per service)                                         │     │
│  │  Event: PubSub message OR tag matching {service}-v*                 │     │
│  │  SA: svc-build-{service}@ops                                        │     │
│  │  Config: deploy/prod-build.yaml                                     │     │
│  │  Approval: MANUAL (Cloud Build approval required)                   │     │
│  │                                                                     │     │
│  │  Steps:                                                             │     │
│  │    1. Copy image from DEV AR → PRD AR                               │     │
│  │    2. Deploy to PRD Cloud Run                                       │     │
│  └─────────────────────────────────────────────────────────────────────┘     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
          │                                                   │
          ▼                                                   ▼
┌──────────────────────┐                     ┌──────────────────────┐
│   DEV (dev-f193)     │                     │   PRD (prd-83ad)     │
├──────────────────────┤                     ├──────────────────────┤
│                      │                     │                      │
│ Artifact Registry    │  image copy ──────► │ Artifact Registry    │
│ (build target)       │                     │ (copied from dev)    │
│                      │                     │                      │
│ Cloud Run Services   │                     │ Cloud Run Services   │
│ (auto on merge)      │                     │ (manual approval)    │
│                      │                     │                      │
│ BigQuery             │                     │ BigQuery             │
│ (source of truth)    │  incremental sync ► │ (synced from DEV)    │
│                      │                     │                      │
│ svc-ai-platform@dev  │                     │ svc-ai-platform@prd  │
└──────────────────────┘                     └──────────────────────┘
```

### Deployment Rules

| Event | DEV | PRD |
|-------|-----|-----|
| Feature branch push | Tests only (no deploy) | - |
| PR opened | Tests + lint (validation) | - |
| Merge to `main` | Auto build + deploy | - |
| PubSub success / Tag `{svc}-vX.X.X` | - | Manual approval → deploy |

---

## Cloud Build Configuration

### Dev Build Template

Create this file in each service repository:

```yaml
# deploy/dev-build.yaml
#
# Triggered by: push to main branch
# SA: svc-build-{service}@rsr-ds-group-ops-d0b0.iam.gserviceaccount.com

substitutions:
  _SERVICE_NAME: taxonomy              # Change per service
  _REGION: us-east1
  _PROJECT_DEV: rsr-ds-group-dev-f193
  _ENV: dev

steps:
  # ─── TEST ───────────────────────────────────────────────
  - id: 'test'
    name: 'python:3.11'
    entrypoint: 'bash'
    args:
      - '-c'
      - |
        pip install -r requirements.txt -r requirements-test.txt
        pytest tests/ --cov=src --cov-report=term-missing

  # ─── LINT ───────────────────────────────────────────────
  - id: 'lint'
    name: 'python:3.11'
    entrypoint: 'bash'
    args:
      - '-c'
      - |
        pip install ruff
        ruff check src/

  # ─── BUILD ──────────────────────────────────────────────
  - id: 'build'
    name: 'gcr.io/cloud-builders/docker'
    args:
      - 'build'
      - '-t'
      - '${_REGION}-docker.pkg.dev/${_PROJECT_DEV}/docker-images/${_SERVICE_NAME}:${COMMIT_SHA}'
      - '-t'
      - '${_REGION}-docker.pkg.dev/${_PROJECT_DEV}/docker-images/${_SERVICE_NAME}:latest'
      - '.'
    waitFor: ['test', 'lint']

  # ─── PUSH ──────────────────────────────────────────────
  - id: 'push'
    name: 'gcr.io/cloud-builders/docker'
    args:
      - 'push'
      - '--all-tags'
      - '${_REGION}-docker.pkg.dev/${_PROJECT_DEV}/docker-images/${_SERVICE_NAME}'
    waitFor: ['build']

  # ─── DEPLOY TO DEV ─────────────────────────────────────
  - id: 'deploy-dev'
    name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
    entrypoint: 'gcloud'
    args:
      - 'run'
      - 'deploy'
      - '${_SERVICE_NAME}'
      - '--image=${_REGION}-docker.pkg.dev/${_PROJECT_DEV}/docker-images/${_SERVICE_NAME}:${COMMIT_SHA}'
      - '--project=${_PROJECT_DEV}'
      - '--region=${_REGION}'
      - '--service-account=svc-ai-platform@${_PROJECT_DEV}.iam.gserviceaccount.com'
      - '--set-env-vars=ENV=${_ENV},BQ_PROJECT=${_PROJECT_DEV},GOOGLE_CLOUD_PROJECT=${_PROJECT_DEV}'
      - '--no-allow-unauthenticated'
    waitFor: ['push']

  # ─── NOTIFY SUCCESS (PubSub) ───────────────────────────
  - id: 'notify'
    name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
    entrypoint: 'gcloud'
    args:
      - 'pubsub'
      - 'topics'
      - 'publish'
      - 'pipelines_build_status'
      - '--project=rsr-ds-group-ops-d0b0'
      - '--message={"service":"${_SERVICE_NAME}","status":"success","commit":"${COMMIT_SHA}","env":"dev"}'
    waitFor: ['deploy-dev']

options:
  logging: CLOUD_LOGGING_ONLY
```

### Prod Build Template

```yaml
# deploy/prod-build.yaml
#
# Triggered by: PubSub message on pipelines_build_status OR tag matching {service}-v*
# SA: svc-build-{service}@rsr-ds-group-ops-d0b0.iam.gserviceaccount.com
# Approval: MANUAL (Cloud Build approval gate)

substitutions:
  _SERVICE_NAME: taxonomy              # Change per service
  _REGION: us-east1
  _PROJECT_DEV: rsr-ds-group-dev-f193
  _PROJECT_PRD: rsr-ds-group-prd-83ad
  _ENV: prd

steps:
  # ─── COPY IMAGE: DEV AR → PRD AR ──────────────────────
  - id: 'copy-image'
    name: 'gcr.io/cloud-builders/docker'
    entrypoint: 'bash'
    args:
      - '-c'
      - |
        docker pull ${_REGION}-docker.pkg.dev/${_PROJECT_DEV}/docker-images/${_SERVICE_NAME}:${COMMIT_SHA}
        docker tag \
          ${_REGION}-docker.pkg.dev/${_PROJECT_DEV}/docker-images/${_SERVICE_NAME}:${COMMIT_SHA} \
          ${_REGION}-docker.pkg.dev/${_PROJECT_PRD}/docker-images/${_SERVICE_NAME}:${COMMIT_SHA}
        docker push ${_REGION}-docker.pkg.dev/${_PROJECT_PRD}/docker-images/${_SERVICE_NAME}:${COMMIT_SHA}

        # Also tag as latest in prod
        docker tag \
          ${_REGION}-docker.pkg.dev/${_PROJECT_DEV}/docker-images/${_SERVICE_NAME}:${COMMIT_SHA} \
          ${_REGION}-docker.pkg.dev/${_PROJECT_PRD}/docker-images/${_SERVICE_NAME}:latest
        docker push ${_REGION}-docker.pkg.dev/${_PROJECT_PRD}/docker-images/${_SERVICE_NAME}:latest

  # ─── DEPLOY TO PRD ─────────────────────────────────────
  - id: 'deploy-prd'
    name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
    entrypoint: 'gcloud'
    args:
      - 'run'
      - 'deploy'
      - '${_SERVICE_NAME}'
      - '--image=${_REGION}-docker.pkg.dev/${_PROJECT_PRD}/docker-images/${_SERVICE_NAME}:${COMMIT_SHA}'
      - '--project=${_PROJECT_PRD}'
      - '--region=${_REGION}'
      - '--service-account=svc-ai-platform@${_PROJECT_PRD}.iam.gserviceaccount.com'
      - '--set-env-vars=ENV=${_ENV},BQ_PROJECT=${_PROJECT_PRD},GOOGLE_CLOUD_PROJECT=${_PROJECT_PRD}'
      - '--no-allow-unauthenticated'
      - '--min-instances=1'
    waitFor: ['copy-image']

options:
  logging: CLOUD_LOGGING_ONLY
```

### Terraform: Cloud Build Trigger Module

```hcl
# infrastructure/terraform/modules/cloud-build-trigger/main.tf

variable "service_name" {}
variable "github_repo" {}
variable "github_owner" {
  default = "randstadrisesmart"
}
variable "region" {
  default = "us-east1"
}
variable "build_sa" {
  description = "Per-service build SA email"
}

# Dev trigger: fires on push to main
resource "google_cloudbuild_trigger" "dev" {
  project  = "rsr-ds-group-ops-d0b0"
  name     = "${var.service_name}-dev"
  location = "global"

  github {
    owner = var.github_owner
    name  = var.github_repo

    push {
      branch = "^main$"
    }
  }

  filename        = "deploy/dev-build.yaml"
  service_account = "projects/rsr-ds-group-ops-d0b0/serviceAccounts/${var.build_sa}"

  substitutions = {
    _SERVICE_NAME = var.service_name
    _REGION       = var.region
    _PROJECT_DEV  = "rsr-ds-group-dev-f193"
    _ENV          = "dev"
  }
}

# Prod trigger: fires on tag matching {service}-v*
resource "google_cloudbuild_trigger" "prd" {
  project  = "rsr-ds-group-ops-d0b0"
  name     = "${var.service_name}-prd"
  location = "global"

  github {
    owner = var.github_owner
    name  = var.github_repo

    push {
      tag = "^${var.service_name}-v\\d+\\.\\d+\\.\\d+$"
    }
  }

  filename        = "deploy/prod-build.yaml"
  service_account = "projects/rsr-ds-group-ops-d0b0/serviceAccounts/${var.build_sa}"

  approval_config {
    approval_required = true
  }

  substitutions = {
    _SERVICE_NAME = var.service_name
    _REGION       = var.region
    _PROJECT_DEV  = "rsr-ds-group-dev-f193"
    _PROJECT_PRD  = "rsr-ds-group-prd-83ad"
    _ENV          = "prd"
  }
}
```

### Terraform: Per-Service Build SA Module

```hcl
# infrastructure/terraform/modules/build-service-account/main.tf

variable "service_name" {}
variable "project_ops" {
  default = "rsr-ds-group-ops-d0b0"
}
variable "project_dev" {
  default = "rsr-ds-group-dev-f193"
}
variable "project_prd" {
  default = "rsr-ds-group-prd-83ad"
}

resource "google_service_account" "build" {
  project      = var.project_ops
  account_id   = "svc-build-${var.service_name}"
  display_name = "Cloud Build SA for ${var.service_name}"
}

# Push images to DEV AR
resource "google_project_iam_member" "ar_writer_dev" {
  project = var.project_dev
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Deploy to DEV Cloud Run
resource "google_project_iam_member" "run_admin_dev" {
  project = var.project_dev
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Act as runtime SA in DEV
resource "google_project_iam_member" "sa_user_dev" {
  project = var.project_dev
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Copy images to PRD AR
resource "google_project_iam_member" "ar_writer_prd" {
  project = var.project_prd
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Read images from DEV AR (for copy step in prod build)
resource "google_project_iam_member" "ar_reader_dev" {
  project = var.project_dev
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Deploy to PRD Cloud Run
resource "google_project_iam_member" "run_admin_prd" {
  project = var.project_prd
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Act as runtime SA in PRD
resource "google_project_iam_member" "sa_user_prd" {
  project = var.project_prd
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Read SSH deploy key from OPS Secret Manager
resource "google_secret_manager_secret_iam_member" "deploy_key" {
  project   = var.project_ops
  secret_id = "ssh-deploy-key-${var.service_name}"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.build.email}"
}

output "build_sa_email" {
  value = google_service_account.build.email
}
```

### Terraform: Instantiate All Services

```hcl
# infrastructure/terraform/environments/ops/cloud-build.tf

locals {
  services = {
    digitaltwin      = { repo = "rsr-ds-digitaltwin" }
    taxonomy         = { repo = "rsr-ds-taxonomy" }
    sociallistening  = { repo = "rsr-ds-sociallistening" }
    qamonitoring     = { repo = "rsr-ds-qamonitoring" }
    mrapipeline      = { repo = "rsr-ds-mrapipeline" }
    rascoeditorllm   = { repo = "rsr-ds-rascoeditorllm" }
    ollama           = { repo = "rsr-ds-ollama" }
    langapi          = { repo = "rsr-ds-langapi" }
    vegas-normalization = { repo = "rsr-ds-vegas-normalization" }
    kaiser-sow       = { repo = "rsr-ds-kaiser-sow" }
    bluedata-norm    = { repo = "rsr-ds-bluedata-normalization" }
    client-eda       = { repo = "rsr-ds-client-eda" }
    sourcing-capacity = { repo = "rsr-ds-sourcing-capacity" }
  }
}

# Create per-service build SAs
module "build_sa" {
  for_each     = local.services
  source       = "../../modules/build-service-account"
  service_name = each.key
}

# Create per-service Cloud Build triggers
module "cloud_build_trigger" {
  for_each     = local.services
  source       = "../../modules/cloud-build-trigger"
  service_name = each.key
  github_repo  = each.value.repo
  build_sa     = module.build_sa[each.key].build_sa_email
}

# PubSub topic for dev→prod pipeline triggering
resource "google_pubsub_topic" "build_status" {
  project = "rsr-ds-group-ops-d0b0"
  name    = "pipelines_build_status"
}

# Artifact Registry in DEV
resource "google_artifact_registry_repository" "dev_docker" {
  project       = "rsr-ds-group-dev-f193"
  location      = "us-east1"
  repository_id = "docker-images"
  format        = "DOCKER"
}

# Artifact Registry in PRD
resource "google_artifact_registry_repository" "prd_docker" {
  project       = "rsr-ds-group-prd-83ad"
  location      = "us-east1"
  repository_id = "docker-images"
  format        = "DOCKER"
}
```

---

## BigQuery Data Strategy

### Summary

1. **Config-driven zero-copy clone** (BQ Scheduled Queries): DEV → PRD, all regions, daily
2. **Master config** (Terraform `cloud-build.tf`): single source of truth — add `sync_tables` entries to a service, PR + merge to `ops`
3. **Cross-project access** (IAM grants only): BI, RiseSmart, Talent ML, Monster, Central Data Lake

All data sync runs entirely within BigQuery — no Python scripts, no external compute, no BQ Data Transfer Service.
Zero-copy clone (`CREATE OR REPLACE TABLE ... CLONE`) creates a snapshot in PRD that shares storage with DEV until rows diverge.
Frequency is controlled per-table in Terraform — the scheduled query runs daily but respects the per-entry setting.

### Terraform Sync Config

Sync config is defined in `source_staged/rsr-ds-gcp/environments/ops/cloud-build.tf` as part of each service's `sync_tables` attribute. Terraform generates a `tracked_tables` VIEW in each `sync_config_*` dataset from these entries.

Each service in `local.services` can include a `sync_tables` list:

```hcl
my-service = {
  repo        = "rsr-ds-my-service"
  sync_tables = [
    { dataset_name = "my_dataset", table_name = "my_table", sync_frequency = "daily", region = "us-east1" },
    { dataset_name = "my_dataset", table_name = "ref_data",  sync_frequency = "once",  region = "us-east1" },
  ]
}
```

| Field | Description |
|-------|-------------|
| `dataset_name` | BQ dataset name (same in DEV and PRD) |
| `table_name` | BQ table name |
| `sync_frequency` | `once` / `daily` / `weekly` / `monthly` |
| `region` | BQ region (`US`, `EU`, `us-east1`, `europe-west1`, `australia-southeast1`) |
| `enabled` | Optional, defaults to `true` — set to `false` to pause sync |

Terraform flattens all services' `sync_tables` into `local.all_sync_entries`, adding the `service` name and `src_project = "rsr-ds-group-dev-f193"` automatically. The `data-sync-config` module then creates a VIEW per region with `SELECT * FROM UNNEST([STRUCT(...), ...])`.

### Frequency Logic

| Value | Behaviour |
|-------|-----------|
| `once` | Clone only if table does not exist in PRD (initial migration) |
| `daily` | Clone on every run |
| `weekly` | Clone if not exists, otherwise only on Monday |
| `monthly` | Clone if not exists, otherwise only on the 1st of the month |

---

## Data Sync Pipeline

### Architecture

```
Terraform (cloud-build.tf → sync_tables per service)
        │
        │  terraform apply generates VIEW
        ▼
OPS BigQuery — one dataset per region:
  sync_config_US                    (US multi-region)
  sync_config_EU                    (EU multi-region)
  sync_config_us_east1              (us-east1)
  sync_config_europe_west1          (europe-west1)
  sync_config_australia_southeast1  (australia-southeast1)
        │
        │  each dataset contains:
        │    tracked_tables  → VIEW (SELECT * FROM UNNEST([STRUCT(...)]))
        │    sync_log        → run history (cloned / skipped / error)
        │
        │  BQ Scheduled Query fires daily per region
        ▼
Zero-copy clone: DEV → PRD
  CREATE OR REPLACE TABLE `rsr-ds-group-prd-83ad.{dataset}.{table}`
  CLONE `rsr-ds-group-dev-f193.{dataset}.{table}`
```

### Scheduled Queries (one per region)

| Query file | Region | BQ Location |
|---|---|---|
| `data_migration/02_sync_clone_us.sql` | US | `US` |
| `data_migration/02_sync_clone_eu.sql` | EU | `EU` |
| `data_migration/02_sync_clone_us_east1.sql` | us-east1 | `us-east1` |
| `data_migration/02_sync_clone_europe_west1.sql` | europe-west1 | `europe-west1` |
| `data_migration/02_sync_clone_australia_southeast1.sql` | australia-southeast1 | `australia-southeast1` |

Each query is pasted into **BQ UI → Scheduled Queries**, set to run every 24 hours, using service account `svc-ai-platform-ops@rsr-ds-group-ops-d0b0.iam.gserviceaccount.com`.

### Setup (run once)

1. Run `terraform apply` on the `ops` branch — this creates the five `sync_config_*` datasets, `tracked_tables` VIEWs, and `sync_log` tables
2. Paste each `02_sync_clone_*.sql` into BQ Scheduled Queries with the correct location and SA
3. Use `data_migration/03_check_sync_log.sql` to monitor run history and errors

### To add a new table to sync

Add a `sync_tables` entry to the service in `environments/ops/cloud-build.tf`, submit a PR, merge to `ops`. Terraform apply updates the `tracked_tables` VIEW. The next daily run picks it up automatically.

### Migration from Google Sheet

If applying to a project that already has Google Sheet external tables:

1. `terraform import` existing datasets + sync_log tables into state
2. Drop the `tracked_tables` external tables in BQ UI (they conflict with the VIEW)
3. `terraform apply` creates the VIEW replacements

---

## IAM & Security

### Service Account Structure

| Project | Service Account | Purpose | Pattern |
|---------|-----------------|---------|---------|
| OPS | `svc-build-{service}@rsr-ds-group-ops-d0b0` | Per-service Cloud Build SA | One per service (13 total) |
| DEV | `svc-ai-platform@rsr-ds-group-dev-f193` | All dev runtime services | Shared across services |
| PRD | `svc-ai-platform@rsr-ds-group-prd-83ad` | All prod runtime services | Shared across services |
| OPS | `svc-ai-platform-ops@rsr-ds-group-ops-d0b0` | BQ data sync scheduled queries | Shared |

### Per-Service Build SAs (13 total)

Each build SA follows the same pattern. All are created in the OPS project.

| Build SA | Service |
|----------|---------|
| `svc-build-digitaltwin@ops` | digitaltwin |
| `svc-build-taxonomy@ops` | taxonomy |
| `svc-build-sociallistening@ops` | sociallistening |
| `svc-build-qamonitoring@ops` | qamonitoring |
| `svc-build-mrapipeline@ops` | mrapipeline |
| `svc-build-rascoeditorllm@ops` | rascoeditorllm |
| `svc-build-ollama@ops` | ollama |
| `svc-build-langapi@ops` | langapi |
| `svc-build-vegas-normalization@ops` | vegas-fields-normalization |
| `svc-build-kaiser-sow@ops` | kaiser-sow-spend-prediction |
| `svc-build-bluedata-norm@ops` | bluedata-normalization (all 6 regions) |
| `svc-build-client-eda@ops` | client-eda |
| `svc-build-sourcing-capacity@ops` | sourcing-capacity-dashboard |

### Per-Service Build SA Roles (same for each)

| Target Project | Role | Purpose |
|----------------|------|---------|
| DEV | `roles/artifactregistry.writer` | Push images to dev AR |
| DEV | `roles/run.admin` | Deploy to dev Cloud Run |
| DEV | `roles/iam.serviceAccountUser` | Set runtime SA on deploy |
| PRD | `roles/artifactregistry.writer` | Copy images to prod AR |
| PRD | `roles/run.admin` | Deploy to prod Cloud Run |
| PRD | `roles/iam.serviceAccountUser` | Set runtime SA on deploy |
| OPS | `roles/secretmanager.secretAccessor` | Read SSH deploy key |

### SSH Deploy Keys

| Secret ID (in OPS) | GitHub Repo |
|---------------------|-------------|
| `ssh-deploy-key-digitaltwin` | `rsr-ds-digitaltwin` |
| `ssh-deploy-key-taxonomy` | `rsr-ds-taxonomy` |
| ... (one per repo) | ... |

### Runtime SA Permissions

Runtime SAs are shared per environment:

```hcl
# infrastructure/terraform/modules/project-iam/main.tf

variable "project_id" {}
variable "environment" {}
variable "ops_project" {
  default = "rsr-ds-group-ops-d0b0"
}

resource "google_service_account" "svc_ai_platform" {
  project      = var.project_id
  account_id   = "svc-ai-platform"
  display_name = "AI Platform Service Account (${var.environment})"
}

# ── Cloud Run ────────────────────────────────────────────────
# Invoke any Cloud Run service in this project (service-to-service calls)
resource "google_project_iam_member" "run_invoker" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.svc_ai_platform.email}"
}

# ── BigQuery ─────────────────────────────────────────────────
# Read/write table data in own project
resource "google_project_iam_member" "bq_data_editor" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.svc_ai_platform.email}"
}

# Run queries in own project
resource "google_project_iam_member" "bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.svc_ai_platform.email}"
}

# ── Secret Manager ───────────────────────────────────────────
# Read shared secrets from OPS (brandwatch-api-key, thinknum-api-key, etc.)
resource "google_project_iam_member" "secrets_ops" {
  project = var.ops_project
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.svc_ai_platform.email}"
}

# Read secrets in own project (e.g. talent-radar-2-rmi-credential in PRD)
resource "google_project_iam_member" "secrets_own" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.svc_ai_platform.email}"
}

# ── Cross-project BQ WRITE (PRD only) ───────────────────────
# External data READ is NOT needed — OPS sync SA copies it into PRD BQ
# via the nightly zero-copy clone pipeline.
resource "google_project_iam_member" "bq_cross_project_write" {
  for_each = toset(["rs-us-talentml2-qa-0001"])
  project  = each.value
  role     = "roles/bigquery.dataEditor"
  member   = "serviceAccount:${google_service_account.svc_ai_platform.email}"
}

output "svc_ai_platform_email" {
  value = google_service_account.svc_ai_platform.email
}
```

### OPS Sync SA Permissions

The OPS sync SA (`svc-ai-platform-ops@rsr-ds-group-ops-d0b0`) runs the nightly BQ Scheduled Queries that zero-copy clone data from DEV → PRD. It does **not** use BQ Data Transfer Service.

| Target Project | Role | Purpose |
|----------------|------|---------|
| OPS (`rsr-ds-group-ops-d0b0`) | `roles/bigquery.jobUser` | Run scheduled queries in OPS |
| DEV (`rsr-ds-group-dev-f193`) | `roles/bigquery.dataViewer` | Read source tables in DEV |
| PRD (`rsr-ds-group-prd-83ad`) | `roles/bigquery.dataOwner` | Create datasets + write cloned tables in PRD |

```hcl
# infrastructure/terraform/environments/ops/data-sync-iam.tf

# OPS sync SA — already exists (created in ops/main.tf)
# data.google_service_account.data_sync.email = svc-ai-platform-ops@rsr-ds-group-ops-d0b0

# Run scheduled queries in OPS
resource "google_project_iam_member" "sync_job_user" {
  project = "rsr-ds-group-ops-d0b0"
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:svc-ai-platform-ops@rsr-ds-group-ops-d0b0.iam.gserviceaccount.com"
}

# Read source tables in DEV
resource "google_project_iam_member" "sync_read_dev" {
  project = "rsr-ds-group-dev-f193"
  role    = "roles/bigquery.dataViewer"
  member  = "serviceAccount:svc-ai-platform-ops@rsr-ds-group-ops-d0b0.iam.gserviceaccount.com"
}

# Create datasets + write cloned tables in PRD
resource "google_project_iam_member" "sync_write_prd" {
  project = "rsr-ds-group-prd-83ad"
  role    = "roles/bigquery.dataOwner"
  member  = "serviceAccount:svc-ai-platform-ops@rsr-ds-group-ops-d0b0.iam.gserviceaccount.com"
}
```

### IAM Summary

| Item | Detail |
|------|--------|
| Build SAs | 13 per-service `svc-build-{name}@ops` |
| Roles per build SA | 8 (AR writer × 2 + AR reader × 1 + run.admin × 2 + SA user × 2 + secret accessor) |
| Runtime SA roles (per env) | 6 (run.invoker + bq.dataEditor + bq.jobUser + secretAccessor × 2 + cross-project write) |
| OPS sync SA roles | 3 (jobUser on OPS + dataViewer on DEV + dataOwner on PRD) |
| Cloud Run agent grants | 0 (AR is per-project, no cross-project read needed) |
| SSH deploy keys | 13 secrets in OPS Secret Manager |
| PubSub | 1 topic + subscriptions in OPS |
| Total IAM bindings | ~119 (build SA × 8 + runtime × 6 × 2 + sync × 3) |

---

## Service-to-Service Communication

All Cloud Run services authenticate to each other using **Google Cloud IAM OIDC tokens**. There are no API keys or shared secrets for internal calls. Services within the same environment call each other directly — DEV calls DEV, PRD calls PRD, no cross-project calls.

### How It Works

Since all services in an environment share the same runtime SA (`svc-ai-platform@{project}`), a single `roles/run.invoker` grant on the target service covers all callers in that environment.

```
┌─────────────────────────────────────────────────────┐
│  DEV (rsr-ds-group-dev-f193)                        │
│                                                     │
│  rascoeditorllm  ──OIDC──►  ollama                  │
│  rascoeditorllm  ──OIDC──►  langapi                 │
│                                                     │
│  All callers: svc-ai-platform@dev                   │
│  Auth: roles/run.invoker on target service          │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│  PRD (rsr-ds-group-prd-83ad)                        │
│                                                     │
│  rascoeditorllm  ──OIDC──►  ollama                  │
│  rascoeditorllm  ──OIDC──►  langapi                 │
│                                                     │
│  All callers: svc-ai-platform@prd                   │
│  Auth: roles/run.invoker on target service          │
└─────────────────────────────────────────────────────┘
```

### Service Dependency Map

| Caller | Target | Purpose |
|--------|--------|---------|
| `rascoeditorllm` | `ollama` | LLM inference |
| `rascoeditorllm` | `langapi` | Language/NLP processing |

> Add rows here as new calling relationships are defined.

### Project-Level Invoker Grant

The `roles/run.invoker` grant is included in the `project-iam` module above. One project-level binding per environment covers all internal service-to-service calls — no per-service or per-caller configuration needed. No updates required when new services are added.

### Calling a Service (Python Pattern)

Each service uses this pattern to make authenticated calls to other internal services:

```python
# src/internal_client.py

import google.auth.transport.requests
import google.oauth2.id_token
import requests
from functools import lru_cache
from src.config import get_config

# Cloud Run service URLs — keyed by environment in config
SERVICE_URLS = {
    "dev": {
        "ollama":       "https://ollama-<hash>-ue.a.run.app",
        "langapi":      "https://langapi-<hash>-ue.a.run.app",
    },
    "prd": {
        "ollama":       "https://ollama-<hash>-ue.a.run.app",
        "langapi":      "https://langapi-<hash>-ue.a.run.app",
    },
}

@lru_cache()
def _auth_session() -> google.auth.transport.requests.Request:
    return google.auth.transport.requests.Request()

def call_service(service: str, path: str, payload: dict) -> dict:
    """Make an IAM-authenticated POST to another internal Cloud Run service."""
    config = get_config()
    base_url = SERVICE_URLS[config.env][service]
    target_url = f"{base_url}{path}"

    token = google.oauth2.id_token.fetch_id_token(_auth_session(), base_url)

    response = requests.post(
        target_url,
        json=payload,
        headers={"Authorization": f"Bearer {token}"},
        timeout=30,
    )
    response.raise_for_status()
    return response.json()


# Usage example (in rascoeditorllm calling ollama):
# result = call_service("ollama", "/generate", {"prompt": "...", "model": "llama3"})
```

### Adding Service URLs to Config

Extend `src/config.py` in each service to include internal service URLs:

```python
@dataclass
class Config:
    env: str
    bq_project: str
    bi_project: str
    log_level: str
    enable_profiling: bool
    elasticsearch_host: str
    min_log_level: str
    service_urls: dict  # internal Cloud Run service URLs

CONFIGS = {
    "dev": Config(
        ...
        service_urls={
            "ollama":       "https://ollama-<hash>-ue.a.run.app",
            "langapi":      "https://langapi-<hash>-ue.a.run.app",
        },
    ),
    "prd": Config(
        ...
        service_urls={
            "ollama":       "https://ollama-<hash>-ue.a.run.app",
            "langapi":      "https://langapi-<hash>-ue.a.run.app",
        },
    ),
}
```

> Replace `<hash>` with the actual Cloud Run URL hash once services are deployed. These are stable — Cloud Run URLs don't change unless the service is deleted and recreated.

### IAM Summary (updated)

| Grant | SA | Role | Target |
|-------|----|------|--------|
| 1 per environment (dev + prd) | `svc-ai-platform@{project}` | `roles/run.invoker` | Project (covers all Cloud Run services) |

One project-level grant per environment — no per-service or per-caller configuration needed.

---

## Environment Configuration in Code

> **Note:** `config.py` is optional. It is a useful pattern for centralizing variables that differ between environments (e.g. project IDs, log levels, feature flags). You are not required to use it — variables can be read directly from `os.environ` or hardcoded where used. Use `config.py` when you find yourself repeating the same env-dependent values across multiple files in a service.

### Config Module

```python
# src/config.py (in each service)

import os
from dataclasses import dataclass
from functools import lru_cache

@dataclass
class Config:
    env: str
    bq_project: str
    bi_project: str
    log_level: str
    enable_profiling: bool
    elasticsearch_host: str
    min_log_level: str

CONFIGS = {
    "dev": Config(
        env="dev",
        bq_project="rsr-ds-group-dev-f193",
        bi_project="rsr-bi-group-prd-701e",
        log_level="DEBUG",
        enable_profiling=True,
        elasticsearch_host="https://es-dev.internal:9200",
        min_log_level="DEBUG",
    ),
    "prd": Config(
        env="prd",
        bq_project="rsr-ds-group-prd-83ad",
        bi_project="rsr-bi-group-prd-701e",
        log_level="WARNING",
        enable_profiling=False,
        elasticsearch_host="https://es-prd.internal:9200",
        min_log_level="WARNING",
    ),
}

@lru_cache()
def get_config() -> Config:
    env = os.environ.get("ENV", "dev")
    return CONFIGS.get(env, CONFIGS["dev"])
```

---

## Ops Project Setup

### What Goes in Ops

```
rsr-ds-group-ops-d0b0/
│
├── Cloud Build
│   ├── Triggers (2 per service: dev + prod)
│   │   ├── rascoeditorllm-dev     → deploy/dev-build.yaml
│   │   ├── rascoeditorllm-prd     → deploy/prod-build.yaml
│   │   ├── taxonomy-dev
│   │   ├── taxonomy-prd
│   │   └── ... (26 triggers total)
│   │
│   └── Service Accounts (per-service build SAs)
│       ├── svc-build-rascoeditorllm@ops
│       ├── svc-build-taxonomy@ops
│       └── ... (13 SAs total)
│
├── PubSub
│   └── pipelines_build_status      # Dev success triggers prod pipeline
│
├── Secret Manager
│   ├── brandwatch-api-key           # Shared runtime secrets
│   ├── thinknum-api-key
│   ├── elasticsearch-password
│   ├── ssh-deploy-key-rascoeditorllm  # Per-repo SSH deploy keys
│   ├── ssh-deploy-key-taxonomy
│   └── ... (13 deploy keys + shared secrets)
│
├── Cloud Logging
│   └── Log sinks from all projects
│       ├── dev-logs-sink
│       └── prd-logs-sink
│
├── Cloud Monitoring
│   ├── Uptime checks for all services
│   ├── Alert policies (incl. build failure alerts)
│   └── Dashboards
│
├── Terraform State
│   └── GCS bucket: rsr-ds-group-ops-terraform-state
│
└── Service Accounts
    ├── svc-build-*@ops              # Per-service build SAs (13)
    └── svc-ai-platform-ops@ops      # For BQ data sync scheduled queries
```

### Ops Terraform Setup

```hcl
# infrastructure/terraform/environments/ops/main.tf

terraform {
  backend "gcs" {
    bucket = "rsr-ds-group-ops-terraform-state"
    prefix = "ops"
  }
}

# Terraform state bucket
resource "google_storage_bucket" "terraform_state" {
  project  = "rsr-ds-group-ops-d0b0"
  name     = "rsr-ds-group-ops-terraform-state"
  location = "US"

  versioning {
    enabled = true
  }
}

# Shared secrets
resource "google_secret_manager_secret" "brandwatch_api_key" {
  project   = "rsr-ds-group-ops-d0b0"
  secret_id = "brandwatch-api-key"
  replication { auto {} }
}

resource "google_secret_manager_secret" "thinknum_api_key" {
  project   = "rsr-ds-group-ops-d0b0"
  secret_id = "thinknum-api-key"
  replication { auto {} }
}

# SSH deploy keys (one per service repo)
resource "google_secret_manager_secret" "deploy_keys" {
  for_each  = local.services
  project   = "rsr-ds-group-ops-d0b0"
  secret_id = "ssh-deploy-key-${each.key}"
  replication { auto {} }
}

# PubSub topic for build status
resource "google_pubsub_topic" "build_status" {
  project = "rsr-ds-group-ops-d0b0"
  name    = "pipelines_build_status"
}

# Data sync SA (unchanged)
resource "google_service_account" "data_sync" {
  project      = "rsr-ds-group-ops-d0b0"
  account_id   = "svc-ai-platform-ops"
  display_name = "AI Platform Ops SA (BQ data sync scheduled queries)"
}

# Build failure alert
resource "google_monitoring_alert_policy" "build_failures" {
  project      = "rsr-ds-group-ops-d0b0"
  display_name = "Cloud Build Failures"

  conditions {
    display_name = "Build failed"
    condition_matched_log {
      filter = <<-EOF
        resource.type="build"
        severity>=ERROR
      EOF
    }
  }

  notification_channels = [var.slack_channel_id]
  alert_strategy {
    notification_rate_limit {
      period = "3600s"
    }
  }
}
```

### Production Environment Terraform

```hcl
# infrastructure/terraform/environments/prd/main.tf

terraform {
  backend "gcs" {
    bucket = "rsr-ds-group-ops-terraform-state"
    prefix = "prd"
  }
}

module "project_iam" {
  source      = "../../modules/project-iam"
  project_id  = "rsr-ds-group-prd-83ad"
  environment = "prd"

  secrets_to_access = [
    "brandwatch-api-key",
    "thinknum-api-key",
    "elasticsearch-password",
  ]
}

# Artifact Registry for prod images
resource "google_artifact_registry_repository" "docker" {
  project       = "rsr-ds-group-prd-83ad"
  location      = "us-east1"
  repository_id = "docker-images"
  format        = "DOCKER"
}

module "rascoeditorllm" {
  source          = "../../modules/cloud-run-service"
  project_id      = "rsr-ds-group-prd-83ad"
  service_name    = "rascoeditorllm"
  region          = "us-east1"
  image           = "us-east1-docker.pkg.dev/rsr-ds-group-prd-83ad/docker-images/rascoeditorllm:latest"
  service_account = module.project_iam.svc_ai_platform_email
  min_instances   = 2  # HIGH traffic
  max_instances   = 10

  env_vars = {
    ENV        = "prd"
    BQ_PROJECT = "rsr-ds-group-prd-83ad"
  }
}

# ... additional services
```

---

## Migration Checklist

### Phase 1: Foundation (Week 1-2)

- [ ] **Set up OPS project infrastructure**
  - [ ] Enable Cloud Build API on OPS project
  - [ ] Create PubSub topic `pipelines_build_status`
  - [ ] Migrate secrets to Secret Manager
  - [ ] Set up cross-project IAM for runtime SAs

- [ ] **Set up Artifact Registry per environment**
  - [ ] Create `docker-images` AR repo in DEV project
  - [ ] Create `docker-images` AR repo in PRD project

- [ ] **Create GitHub repos from templates**
  - [ ] Set up template repo with `deploy/dev-build.yaml` and `deploy/prod-build.yaml`
  - [ ] Configure branch protection rules (per `res-repo-common-repo-rules`)

### Phase 2: Pilot Service (Week 2-3)

- [ ] **Migrate `taxonomy` service first** (simpler, medium traffic)
  - [ ] Create GitHub repo `rsr-ds-taxonomy` from template
  - [ ] Generate SSH deploy key, store in OPS Secret Manager
  - [ ] Create per-service build SA `svc-build-taxonomy@ops`
  - [ ] Grant build SA all required roles (8 roles)
  - [ ] Create Cloud Build triggers (dev + prod) in OPS
  - [ ] Test: merge to main → auto deploy to DEV
  - [ ] Test: create tag → manual approval → deploy to PRD

### Phase 3: Data Migration (Week 3-4)

- [ ] **Run `terraform apply` on `ops` branch** — creates the five `sync_config_*` datasets, `tracked_tables` VIEWs, and `sync_log` tables in OPS BQ
- [ ] **Paste each `02_sync_clone_*.sql` into BQ Scheduled Queries** — one per region, 24h schedule, SA = `svc-ai-platform-ops@rsr-ds-group-ops-d0b0`
- [ ] **Add `sync_tables` entries** — for each table that needs to sync DEV → PRD, add entries to the service in `cloud-build.tf`; set `sync_frequency = "once"` for initial one-time migration, then update to `daily`/`weekly`/`monthly` as appropriate
- [ ] **Verify first run** using `data_migration/03_check_sync_log.sql`
- [ ] **Cross-project IAM grants for BQ** — ensure `svc-ai-platform@prd` has viewer access to external projects

### Phase 4: High-Priority Services (Week 4-6)

> **Note:** `jobsearchsec` and `jobenrichment` are **NOT being migrated**. Support ends Apr 23 2026. They remain as-is in DEV (services, BQ datasets, everything) until then, and will be deleted after support lapses.

- [ ] **Migrate `rascoeditorllm` + `ollama` + `langapi`** (LLM stack)
  - [ ] Create repos, keys, build SAs, triggers
  - [ ] Deploy and test

### Phase 5: Remaining Services (Week 6-8)

- [ ] Migrate `digitaltwin` (add auth!)
- [ ] Migrate `sociallistening`
- [ ] Migrate `qamonitoring`
- [ ] Migrate `mrapipeline`
- [ ] Migrate `vegas-fields-normalization`
- [ ] Migrate `kaiser-sow-spend-prediction`
- [ ] Migrate `bluedata-normalization` (6 regional instances)
- [ ] Migrate `client-eda`
- [ ] Migrate `sourcing-capacity-dashboard`

### Phase 6: Cleanup (Week 8+)

- [ ] Delete `jobsearchsec` and `jobenrichment` from DEV after Apr 23 2026 (support end date)
- [ ] Delete dead services (15 identified)
- [ ] Decommission old monorepo
- [ ] Remove `allUsers` from public Cloud Run services
- [ ] Rotate exposed credentials (API keys, SA keys)
- [ ] Update documentation
- [ ] Verify all Cloud Build triggers fire correctly
- [ ] Verify PubSub-driven prod promotion works for all services

---

## Complete Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                                  GitHub                                               │
│                          randstadrisesmart/ org                                       │
├─────────────────────────────────────────────────────────────────────────────────────┤
│   rsr-ds-rascoeditorllm/     rsr-ds-ollama/              rsr-ds-gcp/       │
│   rsr-ds-digitaltwin/        rsr-ds-taxonomy/            ... (13 repos total)        │
│   rsr-ds-sociallistening/    rsr-ds-qamonitoring/                                    │
└─────────────────────────────────────────────────────────────────────────────────────┘
                                          │
                                          │ Cloud Build triggers
                                          │ (SSH deploy keys for auth)
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                         rsr-ds-group-ops-d0b0 (Operations)                           │
├─────────────────────────────────────────────────────────────────────────────────────┤
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐                   │
│   │ Cloud Build      │  │ Secret Manager   │  │ PubSub           │                   │
│   │ (26 triggers)    │  │ (shared secrets  │  │ (build status    │                   │
│   │ (13 build SAs)   │  │  + deploy keys)  │  │  dev→prod)       │                   │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘                   │
│                                                                                       │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐                   │
│   │ Cloud Logging    │  │ Monitoring       │  │ Terraform State  │                   │
│   │ (aggregated)     │  │ (dashboards +    │  │ (GCS bucket)     │                   │
│   │                  │  │  build alerts)   │  │                  │                   │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘                   │
└─────────────────────────────────────────────────────────────────────────────────────┘
                                          │
             ┌────────────────────────────┴────────────────────────────┐
             ▼                                                         ▼
┌────────────────────────┐                            ┌────────────────────────┐
│   DEV (dev-f193)       │                            │   PRD (prd-83ad)       │
├────────────────────────┤                            ├────────────────────────┤
│ Trigger: merge to main │                            │ Trigger: tag + manual  │
│                        │                            │                        │
│ Artifact Registry      │     image copy ──────────► │ Artifact Registry      │
│ (build target)         │                            │ (copied from dev)      │
│                        │                            │                        │
│ Cloud Run Services     │                            │ Cloud Run Services     │
│ (all services)         │                            │ (all services)         │
│                        │                            │                        │
│ BigQuery               │                            │ BigQuery               │
│ Source of truth        │                            │ (synced from DEV)      │
│                        │  nightly incremental ────► │                        │
│ BQ Scheduled Queries   │                            │                        │
│ (incremental DEV→PRD)  │                            │                        │
│                        │                            │                        │
│ svc-ai-platform@dev    │                            │ svc-ai-platform@prd    │
└────────────────────────┘                            └────────────────────────┘
             │                           │                            │
             └───────────────────────────┴────────────────────────────┘
                                         │
                                         ▼ (WRITE-ONLY cross-project, IAM grant)
                         ┌────────────────────────────────────┐
                         │  rs-us-talentml2-qa-0001  (WRITE)  │
                         │                                    │
                         │  External READ data (BI, RiseSmart,│
                         │  Talent ML, Monster, CDL) is synced│
                         │  into PRD BQ by OPS sync pipeline  │
                         └────────────────────────────────────┘
```

---

*Last updated: 2026-03-09*
