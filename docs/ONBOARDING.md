# Service Onboarding Guide

Step-by-step guide to migrate a service into the CI/CD pipeline.

Replace `{service}` with your service name throughout (e.g. `ollama`, `taxonomy`, `langapi`).

---

## 1. Prepare Your Code

Your service repo should look like this before pushing:

```
rsr-ds-{service}/
├── deploy/
│   ├── dev-build.yaml       # CI/CD pipeline for dev
│   └── prod-build.yaml      # CI/CD pipeline for prod
├── tests/
│   └── test_*.py             # pytest discovers these automatically
├── archive/                  # (optional) dev-only files, not deployed
├── Dockerfile                # builds the deployable image
├── .dockerignore
├── .gitignore
├── server.py                 # (or src/ folder — your app code)
├── requirements.txt          # runtime dependencies
├── requirements-test.txt     # test dependencies (pytest, pytest-cov)
└── start.sh                  # (if needed) container entrypoint
```

### Service requirements

- App must listen on **port 8080**
- Add a health check endpoint (`/healthcheck` or `/health`)
- App must be **stateless** — no local disk state between requests
- Use `ENV` env var (`dev` or `prd`) for environment-specific config — injected
  at deploy time by Cloud Build
- Use **IAM authentication** for backend APIs (`--no-allow-unauthenticated`)
  or **IAP** for user-facing UIs
- Store secrets in **OPS Secret Manager** — do not hardcode credentials or pass
  them as env vars

### Build yamls

Copy the templates from this repo into your service at `deploy/`:

- **Standard service (no GPU):** copy from `templates/deploy/`
- **GPU service (nvidia-l4):** copy from `templates/deploy-gpu/`

Open each file and change `_SERVICE_NAME` from `CHANGE_ME` to your service name.
If your service uses a non-default region, also change `_REGION`.

### requirements.txt

List your runtime Python dependencies. The CI test step runs in a plain
`python:3.11` container (not your Docker image), so it installs these
before running tests.

### requirements-test.txt

```
pytest
pytest-cov
```

### .gitignore

```
__pycache__/
*.pyc
.pytest_cache/
.env
```

Add any service-specific entries (e.g. `*.gguf`, `models/`).

### .dockerignore

```
.git
.gitignore
.dockerignore
__pycache__
*.pyc
.env
tests/
deploy/
archive/
```

---

## 2. Create the GitHub Repo

Go to https://github.com/organizations/randstadrisesmart/repositories/new

- **Name:** `rsr-ds-{service}`
- **Visibility:** Private
- **Do NOT** add a README, .gitignore, or license — the repo must be empty

---

## 3. Initialize Git and Push

Open a terminal in your service folder and run these commands:

```bash
# Initialize a new git repo in this folder
git init

# Stage all files for the first commit
git add .

# Create the first commit
git commit -m "Initial commit: {service} service"

# Rename the default branch from 'master' to 'main'
# (our CI/CD triggers fire on push to 'main', not 'master')
git branch -M main

# Connect your local repo to the GitHub repo you just created
# (this tells git where to push — 'origin' is the standard name for the remote)
git remote add origin git@github.com:randstadrisesmart/rsr-ds-{service}.git

# Push your code to GitHub
# -u sets up tracking so future 'git push' commands just work without extra args
git push -u origin main
```

After this, refresh the GitHub page — you should see your code.

---

## 4. Configure Repo Settings

### Branch protection

Go to **Settings → Branches → Add classic branch protection rule** on the GitHub repo:

- **Branch name pattern:** `main`
- **Require a pull request before merging:** Yes
  - **Require approvals:** 1 (or your team's preference)
- **Require status checks to pass before merging:** Yes
  - Leave the status check search empty for now — we'll come back and add
    the `{service}-pr` check after Step 7 (Add Status Check).

### Merge strategy

Go to **Settings → General → Pull Requests** on the GitHub repo:

- Uncheck **"Allow merge commits"**
- Uncheck **"Allow rebase merging"**
- Keep **"Allow squash merging"** checked

---

## 5. Generate SSH Deploy Key

Cloud Build needs read access to your repo. This is done via an SSH deploy key.

```bash
# Generate a 4096-bit RSA key pair
ssh-keygen -t rsa -b 4096 -f ssh-deploy-key-{service}
# Press Enter twice (no passphrase)
```

This creates two files:
- `ssh-deploy-key-{service}` — the private key (goes to Secret Manager)
- `ssh-deploy-key-{service}.pub` — the public key (goes to GitHub)

### Add public key to GitHub

Go to your repo → **Settings → Deploy keys → Add deploy key**
- **Title:** `cloud-build`
- **Key:** paste the contents of `ssh-deploy-key-{service}.pub`
- **Allow write access:** No (read-only)

### Store private key in OPS Secret Manager

Coordinate with the DataOps team — they manage the OPS project.

```bash
# Create the secret
gcloud secrets create ssh-deploy-key-{service} \
  --project=rsr-ds-group-ops-d0b0

# Upload the private key as the first version
gcloud secrets versions add ssh-deploy-key-{service} \
  --data-file=ssh-deploy-key-{service} \
  --project=rsr-ds-group-ops-d0b0
```

Delete the local key files after uploading:
```bash
rm ssh-deploy-key-{service} ssh-deploy-key-{service}.pub
```

---

## 6. Create Build Service Account (Terraform)

If you don't have the infrastructure repo locally yet, clone it first:

```bash
git clone git@github.com:randstadrisesmart/rsr-ds-gcp.git
cd rsr-ds-gcp
git checkout dev
```

Add your service to `environments/ops/services.tf`:

```hcl
locals {
  services = {
    # ... existing services ...
    {service} = {
      repo        = "rsr-ds-{service}"
      sync_tables = []
    }
  }
}
```

If your service needs a **non-default region** (e.g. GPU services need `us-central1`),
add a `region` field:

```hcl
{service} = {
  repo        = "rsr-ds-{service}"
  region      = "us-central1"       # GPU (nvidia-l4) availability
  sync_tables = []
}
```

If omitted, region defaults to `us-east1`.

If your service has BigQuery tables that need to sync from DEV to PRD, add
entries to `sync_tables`:

```hcl
{service} = {
  repo        = "rsr-ds-{service}"
  sync_tables = [
    { dataset_name = "my_dataset", table_name = "my_table", sync_frequency = "daily", region = "us-east1" },
  ]
}
```

| Field | Description |
|-------|-------------|
| `dataset_name` | BQ dataset name (same in DEV and PRD) |
| `table_name` | BQ table name |
| `sync_frequency` | `once` — clone only if table doesn't exist in PRD (initial migration) |
| | `daily` — clone on every run |
| | `weekly` — clone on Mondays (or if table doesn't exist) |
| | `monthly` — clone on the 1st of the month (or if table doesn't exist) |
| `region` | BQ location: `US`, `EU`, `us-east1`, `europe-west1`, `australia-southeast1` |
| `enabled` | (optional, default `true`) set to `false` to pause sync |

If your service has no BQ tables, use `sync_tables = []`.

Commit, push, and create a PR:

```bash
# Create a branch for your change
git checkout -b feature-onboard-{service}

# Stage and commit
git add environments/ops/services.tf
git commit -m "Add {service} to service registry"

# Push to GitHub
git push -u origin feature-onboard-{service}

```

Now create a Pull Request. You can do this two ways:

**Option A — from the CLI:**
```bash
gh pr create --title "Add {service} to service registry" --body "Onboarding {service} — creates build SA, deploy key secret, PubSub grant."
```
If prompted to choose a base repository, select **`randstadrisesmart/rsr-ds-gcp`**
(not the original Google repo it was forked from).

**Option B — from the GitHub UI:**
Go to the repo on GitHub. You'll see a banner saying your branch had recent
pushes — click **"Compare & pull request"**, fill in the title and description,
and click **"Create pull request"**.

After the PR is reviewed by a supervisor and merged to `dev`, merge `dev` into `ops`
to trigger `terraform apply`:

```bash
git checkout ops
git pull
git merge origin/dev
git push origin ops
```

This creates:
- Build SA: `svc-build-{service}@rsr-ds-group-ops-d0b0.iam.gserviceaccount.com`
- Deploy key secret accessor grant
- PubSub publisher grant
- Cloud Build triggers (dev + prod)

---

## 7. Add Status Check to Branch Protection

Now that the triggers exist, add the PR check to branch protection so PRs
can't be merged without passing tests.

1. Open a test PR (or wait until Step 10 when you test the pipeline)
   — the `{service}-pr` trigger needs to run at least once before GitHub
   knows about it
2. Go to **Settings → Branches → Edit** the `main` protection rule
3. Under **"Require status checks to pass before merging"**, search for
   `{service}-pr` and select it
4. Save changes

From now on, PRs to `main` must pass the Cloud Build check before merging.

---

## 8. Request IAM Bindings from Infra Team

The build SA needs cross-project permissions that are managed by the infra team
(not Terraform). Copy `templates/iam_request_template.csv`, replace `{service}`
with your service name, and submit it as a
[GCP Requests](https://randstadglobal.service-now.com/motion?id=sc_cat_item&sys_id=c1b08a2587285510691d62480cbb3584&referrer=popular_items)
ticket in ServiceNow. The 8 bindings are:

**DEV (`rsr-ds-group-dev-f193`):**
| Role | Purpose |
|------|---------|
| `roles/artifactregistry.writer` | Push images to dev AR |
| `roles/artifactregistry.reader` | Read images from dev AR (for prod copy) |
| `roles/run.admin` | Deploy to dev Cloud Run |
| `roles/iam.serviceAccountUser` | Set runtime SA on deploy |

**PRD (`rsr-ds-group-prd-83ad`):**
| Role | Purpose |
|------|---------|
| `roles/artifactregistry.writer` | Copy images to prod AR |
| `roles/run.admin` | Deploy to prod Cloud Run |
| `roles/iam.serviceAccountUser` | Set runtime SA on deploy |

**OPS (`rsr-ds-group-ops-d0b0`):**
| Role | Purpose |
|------|---------|
| `roles/logging.logWriter` | Write build logs |

Service account: `svc-build-{service}@rsr-ds-group-ops-d0b0.iam.gserviceaccount.com`

---

## 9. Connect Repo to Cloud Build

Before triggers can reference your repo, it must be connected to the Cloud Build
GitHub App in the OPS project.

1. Go to **Cloud Build → Repositories (1st gen)** in the OPS project:
   https://console.cloud.google.com/cloud-build/triggers;region=global/connect?project=rsr-ds-group-ops-d0b0
2. Click **Connect Repository**
3. **Region:** Global
4. **Source:** GitHub (Cloud Build GitHub App)
5. Under **Repository**, if your repo doesn't appear, click **"Edit Repositories on GitHub"**
6. Select your repo (`rsr-ds-{service}`) and click **"Update Access"**
7. Back in Cloud Build, select the repo and confirm the connection

---

## 10. Initial Deploy

### Initial Dev Deploy

In your **service repo** (`rsr-ds-{service}`), push an empty commit to `main`
to trigger the first build and deploy:

```bash
cd /path/to/rsr-ds-{service}
git commit --allow-empty -m "Trigger initial deploy"
git push origin main
```

The `{service}-dev` trigger fires and deploys to DEV.

Check the build in Cloud Build console:
https://console.cloud.google.com/cloud-build/builds?project=rsr-ds-group-ops-d0b0

### Verify DEV

Perform initial smoke tests against the DEV deployment to make sure
everything works to your satisfaction before promoting to production.

### Initial Prod Deploy

Once dev is verified, create a release tag:

```bash
git tag {service}-v1.0.0
git push origin {service}-v1.0.0
```

The `{service}-prd` trigger fires. Go to Cloud Build console → approve the
build → deploys to PRD.

### Verify PRD

Perform smoke tests against the PRD deployment to confirm everything is
working correctly in production.

---

## 11. Celebrate

You're done. Your service is live in production with a full CI/CD pipeline.
