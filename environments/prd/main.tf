terraform {
  backend "gcs" {
    bucket = "rsr-ds-group-ops-terraform-state"
    prefix = "prd"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = "rsr-ds-group-prd-83ad"
  region  = "us-east1"
}

# ── Runtime SA + IAM ────────────────────────────────────────

module "project_iam" {
  source      = "../../modules/project-iam"
  project_id  = "rsr-ds-group-prd-83ad"
  environment = "prd"
}

# ── Cloud Run services (PRD) ────────────────────────────────
# Cloud Build creates/updates these on deploy. Terraform ensures
# baseline config (min instances, env vars) is correct.

module "test_iap_api" {
  source          = "../../modules/cloud-run-service"
  project_id      = "rsr-ds-group-prd-83ad"
  service_name    = "test-iap-api"
  region          = "us-east1"
  image           = "us-east1-docker.pkg.dev/rsr-ds-group-prd-83ad/docker-images/test-iap-api:latest"
  service_account = module.project_iam.svc_ai_platform_email
  min_instances   = 0
  max_instances   = 2

  env_vars = {
    ENV        = "prd"
    BQ_PROJECT = "rsr-ds-group-prd-83ad"
  }
}

module "jobsearchsec" {
  source          = "../../modules/cloud-run-service"
  project_id      = "rsr-ds-group-prd-83ad"
  service_name    = "jobsearchsec"
  region          = "us-east1"
  image           = "us-east1-docker.pkg.dev/rsr-ds-group-prd-83ad/docker-images/jobsearchsec:latest"
  service_account = module.project_iam.svc_ai_platform_email
  min_instances   = 2  # HIGH traffic
  max_instances   = 10

  env_vars = {
    ENV        = "prd"
    BQ_PROJECT = "rsr-ds-group-prd-83ad"
  }
}

module "jobenrichment" {
  source          = "../../modules/cloud-run-service"
  project_id      = "rsr-ds-group-prd-83ad"
  service_name    = "jobenrichment"
  region          = "us-east1"
  image           = "us-east1-docker.pkg.dev/rsr-ds-group-prd-83ad/docker-images/jobenrichment:latest"
  service_account = module.project_iam.svc_ai_platform_email
  min_instances   = 1  # HIGH traffic
  max_instances   = 8

  env_vars = {
    ENV        = "prd"
    BQ_PROJECT = "rsr-ds-group-prd-83ad"
  }
}

# Add remaining services here as they are migrated
