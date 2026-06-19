# rsr-ds-gcp

Infrastructure as Code for the RSR Data Science Group CI/CD platform.

Forked from [GoogleCloudPlatform/solutions-terraform-cloudbuild-gitops](https://github.com/GoogleCloudPlatform/solutions-terraform-cloudbuild-gitops). See the [tutorial](https://cloud.google.com/docs/terraform/resource-management/managing-infrastructure-as-code) for the GitOps pattern.

## Architecture

A single Terraform root — [`environments/ops`](environments/ops) — manages the
CI/CD platform across all three GCP projects. Each resource targets its project
explicitly (`project = ...`), so there is one config and one state file rather
than a separate config per environment.

| Project | Role | What Terraform manages here |
|---------|------|------------------------------|
| `rsr-ds-group-ops-d0b0` | Control plane | Cloud Build triggers, per-group build SAs, PubSub, Secret Manager access, monitoring, BQ data-sync config |
| `rsr-ds-group-dev-f193` | DEV runtime | Artifact Registry (`docker-images`) |
| `rsr-ds-group-prd-83ad` | PRD runtime | Artifact Registry (`docker-images`) |

Runtime service accounts and Cloud Run service definitions are **not** managed
here — each service is built and deployed by its own Cloud Build pipeline (see
`templates/`), and image promotion DEV → PRD happens at the image/tag level, not
via Terraform.

## How it works

Two branches drive the GitOps flow:

| Branch | CI behaviour |
|--------|--------------|
| `dev` (default) | Integration / review branch. PRs land here; Cloud Build runs `terraform plan` only — validation, no changes. |
| `ops` | Apply branch. Merging `dev` → `ops` runs `terraform apply`. |

```
feature branch ──PR──▶ dev   (terraform plan — CI check)
                        │ merge
                        ▼
                       ops    (terraform apply — deploys infra)
```

## Modules

| Module | Purpose |
|--------|---------|
| `build-service-account` | Per-group Cloud Build SA + PubSub publisher (cross-project IAM managed by infra team) |
| `cloud-build-trigger` | Dev trigger (push to main) + prod trigger (tag + manual approval) per service |
| `data-sync-config` | BigQuery scheduled-query config for DEV → PRD table sync |

## Guides

| Guide | When to use |
|-------|------------|
| [`docs/ONBOARDING.md`](docs/ONBOARDING.md) | Adding a new service to the CI/CD pipeline |
| [`docs/WORKFLOW.md`](docs/WORKFLOW.md) | Day-to-day development: branching, PRs, deploying to DEV and PRD |
| [`docs/OFFBOARDING.md`](docs/OFFBOARDING.md) | Removing a service and cleaning up all resources |
| [`docs/CICD_ARCHITECTURE_RSR.md`](docs/CICD_ARCHITECTURE_RSR.md) | Architecture reference for the CI/CD pipeline |

Build yaml templates are in `templates/deploy/` (standard) and `templates/deploy-gpu/` (GPU).

## Local usage

```bash
# Authenticate
gcloud auth application-default login

# Plan (dry run)
cd environments/ops
terraform init
terraform plan

# Apply
terraform apply
```

## Terraform state

Stored in GCS: `rsr-ds-group-ops-terraform-state` bucket, prefixed by environment (`ops/`, `dev/`, `prod/`).

## Reference

Full architecture details: see `CICD_ARCHITECTURE_RSR.md` in the apilegacy repo.
