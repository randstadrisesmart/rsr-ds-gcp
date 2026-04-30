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

