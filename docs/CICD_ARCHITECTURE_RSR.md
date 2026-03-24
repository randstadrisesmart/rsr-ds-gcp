# CI/CD Architecture Reference

**Project:** RSR Data Science Group
**Architecture:** Multi-Repo + GitHub + Cloud Build + Shared Build SAs (per group)

For step-by-step onboarding instructions, see [`ONBOARDING.md`](ONBOARDING.md).

---

## Table of Contents

1. [Environment Overview](#environment-overview)
2. [Repository Structure](#repository-structure)
3. [CI/CD Pipeline Flow](#cicd-pipeline-flow)
4. [BigQuery Data Sync](#bigquery-data-sync)
5. [IAM & Security](#iam--security)
6. [Secret Management](#secret-management)
7. [Service-to-Service Communication](#service-to-service-communication)
8. [Environment Configuration in Code](#environment-configuration-in-code)
9. [Architecture Diagram](#architecture-diagram)

---

## Environment Overview

| Project | ID | Purpose | Deployment Trigger |
|---------|-----|---------|-------------------|
| **DEV** | `rsr-ds-group-dev-f193` | Development, testing | Merge to `main` |
| **PRD** | `rsr-ds-group-prd-83ad` | Production workloads | Tag `{service}-vX.X.X` + manual approval |
| **OPS** | `rsr-ds-group-ops-d0b0` | Cloud Build, Secret Manager, PubSub, Terraform state, monitoring | N/A |

- DEV is the source of truth for data. PRD is synced nightly via zero-copy clone.
- OPS is shared infrastructure only — no services run here.

---

## Repository Structure

```
GitHub Organization: randstadrisesmart/
│
├── rsr-ds-{service}/          # One repo per service
│   ├── deploy/
│   │   ├── dev-build.yaml     # CI/CD for dev (push to main)
│   │   ├── prod-build.yaml    # CI/CD for prod (tag)
│   │   └── pr-build.yaml      # PR check (test + lint)
│   ├── src/                   # App code
│   ├── tests/
│   ├── Dockerfile
│   ├── requirements.txt
│   └── ...
│
└── rsr-ds-gcp/                # Infrastructure as Code
    ├── environments/
    │   ├── ops/               # Cloud Build triggers, build SAs, data sync
    │   ├── dev/               # Runtime SA + IAM for DEV
    │   └── prod/              # Runtime SA + IAM + Cloud Run for PRD
    ├── modules/
    └── templates/             # Build yaml templates, IAM request CSVs
```

### Naming Conventions

| Item | Pattern | Example |
|------|---------|---------|
| Service repo | `rsr-ds-{service}` | `rsr-ds-sociallistening` |
| Feature branch | `feature-{service}-{description}` | `feature-taxonomy-add-caching` |
| Tag (prod release) | `{service}-v{X.X.X}` | `taxonomy-v1.2.3` |
| Merge strategy | Squash and merge | Single commit on main per feature |

---

## CI/CD Pipeline Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              GitHub Repos                                   │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐        │
│  │  service A   │ │  service B   │ │  service C   │ │  service D   │        │
│  └──────┬───────┘ └──────┬───────┘ └──────┬───────┘ └──────┬───────┘        │
└─────────┼────────────────┼────────────────┼────────────────┼────────────────┘
          │                │                │                │
          ▼                ▼                ▼                ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Cloud Build (OPS Project)                                │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  DEV TRIGGER (per service)                                          │    │
│  │  Event: push to main                                                │    │
│  │  SA: svc-build-{group}@ops                                          │    │
│  │                                                                     │    │
│  │  Steps: test → lint → build → push to DEV AR → deploy to DEV        │    │
│  │         Cloud Run → notify PubSub                                   │    │
│  └────────────────────────────────┬────────────────────────────────────┘    │
│                                   │                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  PROD TRIGGER (per service)                                         │    │
│  │  Event: tag matching {service}-v*                                   │    │
│  │  SA: svc-build-{group}@ops                                          │    │
│  │  Approval: MANUAL                                                   │    │
│  │                                                                     │    │
│  │  Steps: copy image DEV AR → PRD AR → deploy to PRD Cloud Run        │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
          │                                                   │
          ▼                                                   ▼
┌──────────────────────┐                     ┌──────────────────────┐
│   DEV (dev-f193)     │                     │   PRD (prd-83ad)     │
├──────────────────────┤                     ├──────────────────────┤
│ Artifact Registry    │  image copy ──────► │ Artifact Registry    │
│ Cloud Run Services   │                     │ Cloud Run Services   │
│ BigQuery (source)    │  nightly sync ────► │ BigQuery (clone)     │
│ svc-ai-platform@dev  │                     │ svc-ai-platform@prd  │
└──────────────────────┘                     └──────────────────────┘
```

### Deployment Rules

| Event | DEV | PRD |
|-------|-----|-----|
| Feature branch push | Tests only (no deploy) | - |
| PR opened | Tests + lint (validation) | - |
| Merge to `main` | Auto build + deploy | - |
| Tag `{service}-vX.X.X` | - | Manual approval → deploy |

---

## BigQuery Data Sync

DEV is the source of truth for all data. PRD receives nightly zero-copy clones
from DEV via BQ Scheduled Queries running in OPS.

### How it works

1. Each service declares `sync_tables` in `environments/ops/services.tf`
2. Terraform generates a `tracked_tables` VIEW per region in OPS BigQuery
3. BQ Scheduled Queries run daily per region, reading the VIEW and cloning
   tables from DEV → PRD using `CREATE OR REPLACE TABLE ... CLONE`

```
services.tf (sync_tables per service)
        │  terraform apply
        ▼
OPS BigQuery — one dataset per region:
  sync_config_US, sync_config_EU, sync_config_us_east1, ...
        │  each contains: tracked_tables VIEW + sync_log table
        │  BQ Scheduled Query fires daily
        ▼
Zero-copy clone: DEV → PRD
```

### Frequency options

| Value | Behaviour |
|-------|-----------|
| `once` | Clone only if table does not exist in PRD |
| `daily` | Clone on every run |
| `weekly` | Clone on Mondays (or if table doesn't exist) |
| `monthly` | Clone on the 1st of the month (or if table doesn't exist) |

### Sync SA

The OPS sync SA (`svc-ai-platform-ops@rsr-ds-group-ops-d0b0`) runs the
scheduled queries. It needs:

| Target Project | Role | Purpose |
|----------------|------|---------|
| OPS | `roles/bigquery.jobUser` | Run scheduled queries |
| DEV | `roles/bigquery.dataViewer` | Read source tables |
| PRD | `roles/bigquery.dataOwner` | Create datasets + write cloned tables |

---

## IAM & Security

### Service Account Structure

| Project | Service Account | Purpose |
|---------|-----------------|---------|
| OPS | `svc-build-{group}@rsr-ds-group-ops-d0b0` | Shared build SA per group |
| DEV | `svc-ai-platform@rsr-ds-group-dev-f193` | All dev runtime services |
| PRD | `svc-ai-platform@rsr-ds-group-prd-83ad` | All prod runtime services |
| OPS | `svc-ai-platform-ops@rsr-ds-group-ops-d0b0` | BQ data sync |

### Build groups

Services share a build SA by group. Services in the same group use
`svc-build-{group}@ops`. See `environments/ops/services.tf` for the current
list.

| Group | Purpose |
|-------|---------|
| `ollama` | LLM backed services |
| `talent` | Talent Radar |
| `analysis` | Other analysis services |

### Build SA roles (same for each group)

| Target Project | Role | Purpose |
|----------------|------|---------|
| DEV | `roles/artifactregistry.writer` | Push images to dev AR |
| DEV | `roles/artifactregistry.reader` | Read images (for prod copy step) |
| DEV | `roles/run.admin` | Deploy to dev Cloud Run |
| DEV | `roles/iam.serviceAccountUser` | Set runtime SA on deploy |
| PRD | `roles/artifactregistry.writer` | Copy images to prod AR |
| PRD | `roles/run.admin` | Deploy to prod Cloud Run |
| PRD | `roles/iam.serviceAccountUser` | Set runtime SA on deploy |

> Build SA roles are requested from the infra team via ServiceNow — see
> [ONBOARDING.md Step 5](ONBOARDING.md#5-request-iam-bindings-from-infra-team).

### Runtime SA roles (per environment)

| Target | Role | Purpose |
|--------|------|---------|
| Own project | `roles/run.invoker` | Service-to-service calls |
| Own project | `roles/bigquery.dataEditor` | Read/write BQ tables |
| Own project | `roles/bigquery.jobUser` | Run queries |
| OPS project | `roles/secretmanager.secretAccessor` | Read runtime secrets |

---

## Secret Management

All secrets live in **OPS Secret Manager**. There are two types:

| Type | When it's used | Who reads it | How access is granted |
|------|---------------|-------------|---------------------|
| **Build-time** | During `docker build` | Build SA (`svc-build-{group}@ops`) | Per-secret, via `build_secrets` in `services.tf` |
| **Runtime** | While the app is running | Runtime SA (`svc-ai-platform@dev/prd`) | Project-level `secretAccessor` on OPS |

- **Build-time secrets** are listed in `build_secrets` in `services.tf`.
  Terraform grants per-secret access to the build SA.
- **Runtime secrets** are fetched by the app via the Secret Manager API at
  startup. No Terraform or deploy yaml changes needed — the runtime SAs
  already have project-level access to all secrets in OPS.

See [ONBOARDING.md Section 1.3](ONBOARDING.md#13-secrets) for instructions on
creating and using secrets.

---

## Service-to-Service Communication

All Cloud Run services authenticate to each other using **Google Cloud IAM
OIDC tokens**. There are no API keys or shared secrets for internal calls.

Since all services in an environment share the same runtime SA
(`svc-ai-platform@{project}`), a single `roles/run.invoker` grant on the
project covers all callers in that environment.

```
┌──────────────────────────────────────────────────────┐
│  DEV / PRD                                           │
│                                                      │
│  service A  ──OIDC──►  service B                     │
│  service A  ──OIDC──►  service C                     │
│                                                      │
│  All callers: svc-ai-platform@{project}              │
│  Auth: roles/run.invoker (project-level)             │
└──────────────────────────────────────────────────────┘
```

### Python pattern

```python
import google.auth.transport.requests
import google.oauth2.id_token
import requests
from functools import lru_cache

@lru_cache()
def _auth_session():
    return google.auth.transport.requests.Request()

def call_service(base_url: str, path: str, payload: dict) -> dict:
    """Make an IAM-authenticated POST to another internal Cloud Run service."""
    token = google.oauth2.id_token.fetch_id_token(_auth_session(), base_url)
    response = requests.post(
        f"{base_url}{path}",
        json=payload,
        headers={"Authorization": f"Bearer {token}"},
        timeout=30,
    )
    response.raise_for_status()
    return response.json()
```

---

## Environment Configuration in Code

Services use the `ENV` env var (`dev` or `prd`) injected at deploy time to
determine environment-specific config. The simplest approach is reading
`os.environ` directly:

```python
import os
PROJECT_ID = os.environ.get('GCP_PROJECT_ID', 'rsr-ds-group-dev-f193')
```

For services with many environment-dependent values, a config module can help:

```python
# src/config.py
import os
from dataclasses import dataclass
from functools import lru_cache

@dataclass
class Config:
    env: str
    bq_project: str

CONFIGS = {
    "dev": Config(env="dev", bq_project="rsr-ds-group-dev-f193"),
    "prd": Config(env="prd", bq_project="rsr-ds-group-prd-83ad"),
}

@lru_cache()
def get_config() -> Config:
    env = os.environ.get("ENV", "dev")
    return CONFIGS.get(env, CONFIGS["dev"])
```

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                                  GitHub                                             │
│                          randstadrisesmart/ org                                     │
│   rsr-ds-{service}/  ×N                          rsr-ds-gcp/ (IaC)                  │
└─────────────────────────────────────────────────────────────────────────────────────┘
                                          │
                                          │ Cloud Build triggers
                                          │ (GitHub App connection)
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                         rsr-ds-group-ops-d0b0 (Operations)                          │
├─────────────────────────────────────────────────────────────────────────────────────┤
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐                  │
│   │ Cloud Build      │  │ Secret Manager   │  │ PubSub           │                  │
│   │ (2 triggers/svc) │  │ (shared secrets) │  │ (build status)   │                  │
│   │ (build SAs/group)│  │                  │  │                  │                  │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘                  │
│                                                                                     │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐                  │
│   │ Cloud Logging    │  │ Monitoring       │  │ Terraform State  │                  │
│   │ (aggregated)     │  │ (dashboards +    │  │ (GCS bucket)     │                  │
│   │                  │  │  build alerts)   │  │                  │                  │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘                  │
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
│ Cloud Run Services     │                            │ Cloud Run Services     │
│ BigQuery (source)      │     nightly sync ────────► │ BigQuery (clone)       │
│ svc-ai-platform@dev    │                            │ svc-ai-platform@prd    │
└────────────────────────┘                            └────────────────────────┘
```
