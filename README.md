# rsr-ds-gcp

Infrastructure as Code for the RSR Data Science Group CI/CD platform.

Forked from [GoogleCloudPlatform/solutions-terraform-cloudbuild-gitops](https://github.com/GoogleCloudPlatform/solutions-terraform-cloudbuild-gitops). See the [tutorial](https://cloud.google.com/docs/terraform/resource-management/managing-infrastructure-as-code) for the GitOps pattern.

## Architecture

Three GCP projects, managed by environment branches:

| Branch | Project | What it manages |
|--------|---------|----------------|
| `ops` | `rsr-ds-group-ops-d0b0` | Cloud Build triggers, per-service build SAs, PubSub, Artifact Registry, Secret Manager, monitoring |
| `dev` | `rsr-ds-group-dev-f193` | Runtime SA (`svc-ai-platform@dev`) + IAM bindings |
| `prd` | `rsr-ds-group-prd-83ad` | Runtime SA (`svc-ai-platform@prd`) + IAM bindings + Cloud Run service definitions |

## How it works

Push to a branch named after an environment → Cloud Build runs `terraform apply` for that environment. Push to any other branch → `terraform plan` only (validation, no changes).

```
feature branch → terraform plan (CI check)
       ↓ merge
ops/dev/prd branch → terraform apply (deploys infra)
```

## Modules

| Module | Purpose |
|--------|---------|
| `build-service-account` | Per-service Cloud Build SA + 7 IAM role bindings (AR writer, run.admin, SA user on DEV+PRD, secret accessor on OPS) |
| `cloud-build-trigger` | Dev trigger (push to main) + prod trigger (tag + manual approval) per service |
| `cloud-run-service` | Cloud Run service definition with scaling, env vars, no-public-access |
| `project-iam` | Runtime SA (`svc-ai-platform`) + roles (run.invoker, BQ, Secret Manager) |

## Adding a new service

1. Add a row to `environments/ops/cloud-build.tf` → `local.services`
2. Push to `ops` branch → creates build SA + Cloud Build triggers
3. Add a Cloud Run module in `environments/prd/main.tf` (if PRD needs specific scaling)
4. Push to `prd` branch → creates the service definition

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

Stored in GCS: `rsr-ds-group-ops-terraform-state` bucket, prefixed by environment (`ops/`, `dev/`, `prd/`).

## Reference

Full architecture details: see `CICD_ARCHITECTURE_RSR.md` in the apilegacy repo.
