# Service Onboarding Guide

Step-by-step guide to migrate a service into the CI/CD pipeline.

Replace `{service}` with your service name throughout (e.g. `ollama`, `taxonomy`, `langapi`).

---

## 1. Prepare Your Code

Your service repo should look like this before pushing:

```
rsr-ds-{service}/
├── .github/
│   └── CODEOWNERS            # restricts who can approve PRs
├── deploy/
│   ├── dev-build.yaml        # CI/CD pipeline for dev
│   └── prod-build.yaml       # CI/CD pipeline for prod
├── tests/
│   └── test_*.py             # pytest discovers these automatically
├── archive/                  # anything not needed for deployment
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
- Add a health check endpoint `/health`
- App must be **stateless** — no local disk state between requests
- Use `ENV` env var (`dev` or `prd`) for environment-specific config — injected
  at deploy time by Cloud Build
- External credentials, API keys, or secrets must be stored in **OPS Secret
  Manager** or passed at build time as env vars — no hardcoded strings

### CODEOWNERS

Copy the CODEOWNERS file from this repo into your service:

```bash
cp -r /path/to/rsr-ds-gcp/templates/.github .github
```

### Build yamls

Copy the templates from this repo into your service at `deploy/`:

- **Standard service (no GPU):** copy from `templates/deploy/`
- **GPU service (nvidia-l4):** copy from `templates/deploy-gpu/`

Open each file and review the substitutions at the top:

| Substitution | Default | When to change |
|-------------|---------|----------------|
| `_SERVICE_NAME` | `CHANGE_ME` | **Always** — set to your service name |
| `_REGION` | `us-east1` | If co-locating with a dependency (e.g. `europe-west1`) |
| `_MEMORY` | `512Mi` | If loading heavy models at startup (e.g. `32Gi`) |
| `_CPU` | `1` | If loading heavy models at startup (e.g. `4`) |
| `_TIMEOUT` | `300` | If startup takes more than 5 min (e.g. `1800` = 30 min) |

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
.ruff_cache/
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
.pytest_cache/
.ruff_cache/
.env
tests/
deploy/
archive/
```

### Pre-flight: lint and test locally

CI will reject your first push if lint or tests fail. Save yourself a round-trip:

```bash
pip install ruff pytest pytest-cov
ruff check . --exclude archive/   # fix any issues before pushing
pytest tests/
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
# (our CI/CD triggers fire on push to 'main', not 'master'
# as a pre 2020 convention)
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
  - **Require review from Code Owners:** Yes
- **Require status checks to pass before merging:** Yes
  - Leave the status check search empty for now — we'll come back and add
    the `{service}-pr` check after Step 9 (Add Status Check).

### Merge strategy

Go to **Settings → General → Pull Requests** on the GitHub repo:

- Uncheck **"Allow merge commits"**
- Uncheck **"Allow rebase merging"**
- Keep **"Allow squash merging"** checked

---

## 5. Create Build Service Account (Terraform)

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
      repo          = "rsr-ds-{service}"
      build_group   = "ollama"              # see Build Groups below
      build_secrets = ["name"]              # see Build Secrets below
      sync_tables   = []
    }
  }
}
```

### Build groups

Services share a build SA by group. All services in the same group use
`svc-build-{group}@ops`. IAM bindings are requested once per group — if the
group already exists, no new IAM request is needed (skip Step 6).

| Group | Purpose | Services |
|-------|---------|----------|
| `ollama` | LLM backed services | ollama, cleanpii, rascoeditorllm |
| `talent` | Talent Radar | taxonomy, digitaltwin |
| `analysis` | Other analysis | sociallistening, qamonitoring, mrapipeline, etc. |

Pick the group that fits your service. If none fits, create a new group name —
Terraform will create the SA automatically, and you'll need to request IAM
bindings for it (Step 6).

### Optional fields

**`region`** — Cloud Run / AR region. Defaults to `us-east1`. Set this if your
service needs a specific region (e.g. co-locate with a dependency, or GPU
availability):

```hcl
{service} = {
  repo        = "rsr-ds-{service}"
  build_group = "ollama"
  region      = "europe-west1"       # co-locate with ollama
  sync_tables = []
}
```

**`build_secrets`** — list of OPS Secret Manager secret IDs the build SA needs
access to at build time (e.g. `hf-token` for HuggingFace downloads). Terraform
grants `secretmanager.secretAccessor` on each secret to the group's build SA.
Omit if your build doesn't need any secrets.

**`sync_tables`** — BigQuery tables to sync from DEV to PRD. Use
`sync_tables = []` if your service has no BQ tables.

```hcl
{service} = {
  repo        = "rsr-ds-{service}"
  build_group = "analysis"
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

Commit, push, and create a PR **in the rsr-ds-gcp repo** (not your service repo):

```bash
# Make sure you're in the infrastructure repo, not your service repo!
cd /path/to/rsr-ds-gcp

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

If the build SA didn't already exist, Terraform creates:
- Build SA: `svc-build-{build_group}@rsr-ds-group-ops-d0b0.iam.gserviceaccount.com`
- PubSub publisher grant for the build SA
- The new SA needs IAM bindings from the infra team — see Step 6

Terraform always creates:
- Cloud Build triggers (dev + prod) for this service

---

## 6. Request IAM Bindings from Infra Team

> **Skip this step** if your service's `build_group` SA already has IAM bindings
> (i.e. another service in the same group was onboarded before).

The build SA needs cross-project permissions that are managed by the infra team
(not Terraform). Copy `templates/iam_request_template.csv`, replace `{service}`
with your build group name, and submit it as a
[GCP Requests](https://randstadglobal.service-now.com/motion?id=sc_cat_item&sys_id=c1b08a2587285510691d62480cbb3584&referrer=popular_items)
ticket in ServiceNow. 

---

## 7. Connect Repo to Cloud Build

Before triggers can reference your repo, it must be connected to the Cloud Build
GitHub App in the OPS project.

1. Go to **Cloud Build → Repositories (1st gen)** in the OPS project:
   https://console.cloud.google.com/cloud-build/triggers;region=global/connect?project=rsr-ds-group-ops-d0b0
2. Click **Connect Repository**
3. **Region:** Global
4. **Source:** GitHub (Cloud Build GitHub App)
5. Under **Repository**, if your repo doesn't appear, click **"Edit Repositories on GitHub"**
6. Select your repo (`rsr-ds-{service}`) and click **"Update Access"**
7. Back in Connect repositoy, select the repo and confirm the connection
8. Click **Done**

---

## 8. Initial Deploy

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

## 9. Add Status Check to Branch Protection

Now that the first build has run, add the PR check to branch protection
in your **service repo** (`rsr-ds-{service}`) on GitHub:

1. Go to **Settings → Branches → Edit** the `main` protection rule
2. Under **"Require status checks to pass before merging"**, search for
   `{service}-pr` and select it
3. Save changes

From now on, PRs to `main` must pass the Cloud Build check before merging.

---

## 10. Celebrate

You're done. Your service is live in production with a full CI/CD pipeline.
