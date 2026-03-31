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
│   ├── pr-build.yaml         # PR status check (test + lint only)
│   ├── dev-build.yaml        # CI/CD pipeline for dev
│   └── prod-build.yaml       # CI/CD pipeline for prod
├── src/                      # Python modules referenced by main.py
│   ├── module_a.py
│   └── module_b.py
├── tests/                    # unit tests — run by CI in a bare python:3.11 container
│   └── test_*.py             # pytest discovers these automatically
├── integration_tests/        # integration tests — run locally by developers (not CI)
├── archive/                  # anything not needed for deployment
├── Dockerfile                # builds the deployable image
├── .dockerignore
├── .gitignore
├── main.py                   # entry point — imports from src/
├── requirements.txt          # runtime dependencies
├── requirements-test.txt     # test dependencies (pytest, pytest-cov)
└── start.sh                  # (if needed) container entrypoint
```

> **Restructure your project to match this layout.** The CI pipeline
> hardcodes `--cov=src` for test coverage, so your application modules
> **must** be in `src/`. If your existing code uses a different directory
> (e.g. `helpers/`, `lib/`), rename it to `src/` and update all imports.
> Move any files not needed at runtime (training scripts, notebooks,
> exploration code, old models, credential files) into `archive/`.
> Delete any service account key files (`*.json` with `private_key`) —
> they must not be committed.

**Unit tests vs integration tests:** The CI test step runs `pytest tests/`
in a bare `python:3.11` container — not your Docker image. Tests in
`tests/` must work without the full runtime environment (no NLTK data,
no spaCy models, no GCS model downloads, etc.). Use mocks for anything
that needs the real environment.

Tests that need the full runtime — loading real models, calling real NLP
pipelines, hitting real GCS buckets — belong in `integration_tests/`.
These are **not run by CI**. Developers run them locally during
development, either against local code (with the full environment set
up) or against the deployed DEV service URL. The DEV environment is the
integration test environment.

### 1.1 Service requirements

- App must listen on **port 8080**
- Add a health check endpoint `/health`
- App must be **stateless** — no local disk state between requests
- Use `ENV` env var (`dev` or `prd`) for environment-specific config — injected
  at deploy time by Cloud Build
- External credentials, API keys, or secrets must be stored in **Ops Secret
  Manager** — no hardcoded strings (see 1.3)
- **No local credential files** — delete any `adc.json`, service account key
  files, or personal gcloud credential files from the repo. Remove or guard
  any `os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = ...` lines in source
  code. On Cloud Run, the service account provides credentials automatically
  via Application Default Credentials (ADC) — no credential files are needed.
  Hardcoded paths to local `adc.json` or `~/.config/gcloud/` files will cause
  `DefaultCredentialsError` at runtime.
- No file larger than **10 MB** in the repo — large data files should be
  uploaded to a GCS bucket and downloaded at startup (see 1.2)

### 1.2 GCS data and large files

**Any data your service needs at runtime (models, reference data, geojson,
etc.) must be baked into the Docker image at build time.** Services must
not download from GCS at runtime — the PRD runtime SA does not have access
to DEV buckets, and runtime downloads add cold-start latency. Use the
`_GCS_BUCKET` and `_GCS_DIRECTORIES` substitutions in your build yaml to
download data during the CI build step, then load from the local filesystem
at runtime (see below).

Files over 10 MB should not be committed to git. Upload them to a GCS
bucket instead. The shared bucket `location_object` in DEV is used for
this — both the DEV and PRD build SAs have read access to it.

#### Uploading to GCS

**Option A — from the console:**

1. Go to **Cloud Storage → Buckets** in the DEV project:
   https://console.cloud.google.com/storage/browser?project=rsr-ds-group-dev-f193
2. Open the bucket (e.g. `location_object`) or create a new one
3. Click **Upload Files** or **Upload Folder**
4. Navigate to and select the files to upload

**Option B — from the CLI:**

```bash
# Upload a single file
gcloud storage cp ./path/to/large_file.json gs://location_object/my_folder/

# Upload an entire directory
gcloud storage cp -r ./geojsonMaps gs://location_object/geojsonMaps/
```

#### Downloading at build time (recommended)

The build yamls include a `download-gcs-data` step that downloads files from
GCS and bakes them into the Docker image. Set the `_GCS_BUCKET` and
`_GCS_DIRECTORIES` substitutions in your `dev-build.yaml` (see §1.5):

```yaml
_GCS_BUCKET: location_object
_GCS_DIRECTORIES: 'geojsonMaps,models,reference_data'
```

The data is baked into the DEV image at build time. The prod pipeline copies
that same image — no re-download needed.

Your application code should load from the local filesystem, not from GCS:

```python
# Good — load from local path (baked into image at build time)
with open('model/my_model.sav', 'rb') as f:
    model = pickle.load(f)

# Bad — downloads from GCS at runtime (won't work in PRD)
model = download_from_gcs('my-bucket', 'model/my_model.sav')
```

Add the GCS data paths to `.gitignore` so they aren't committed.

### 1.3 Secrets

> **Skip this** if your service has no secrets (no API keys, no
> credentials, no encryption keys).

All secrets live in **OPS Secret Manager** (`rsr-ds-group-ops-d0b0`). There
are two types depending on when the secret is needed:

| Type | When it's used | Who reads it | How access is granted |
|------|---------------|-------------|---------------------|
| **Build-time** | During `docker build` (e.g. downloading models) | Build SA (`svc-build-{group}@ops`) | Per-secret, via `build_secrets` in `services.tf` |
| **Runtime** | While the app is running (e.g. API keys) | Runtime SA (`svc-ai-platform@dev/prd`) | Project-level, already granted |

#### Creating a secret

**Option A — from the console:**

1. Go to **Security → Secret Manager** in the OPS project:
   https://console.cloud.google.com/security/secret-manager?project=rsr-ds-group-ops-d0b0
2. Click **Create Secret**
3. Enter a name (e.g. `es-api-key`)
4. Paste the secret value or upload a file
5. Click **Create Secret**

**Option B — from the CLI:**

```bash
# From a value
echo -n "your-secret-value" | gcloud secrets create {secret-name} \
  --project=rsr-ds-group-ops-d0b0 --data-file=- --replication-policy=automatic

# From a file
gcloud secrets create {secret-name} \
  --project=rsr-ds-group-ops-d0b0 --data-file=/path/to/file.json \
  --replication-policy=automatic
```

#### Updating a secret

```bash
echo -n "new-value" | gcloud secrets versions add {secret-name} \
  --project=rsr-ds-group-ops-d0b0 --data-file=-
```

#### Build-time secrets

If a secret is needed during `docker build` (e.g. `hf-token` for downloading
HuggingFace models), add it to `build_secrets` in `services.tf` (see Step 3):

```hcl
build_secrets = ["hf-token"]
```

Terraform grants `secretmanager.secretAccessor` on each listed secret to
the group's build SA. Then reference the secret in your build yaml using
Cloud Build's `--secret-env` or `secretEnv` syntax.

#### Runtime secrets

If a secret is needed while the app is running, there are two options:

**Option A — `_RUNTIME_SECRETS` substitution (recommended):**

Set the `_RUNTIME_SECRETS` substitution in `dev-build.yaml` and
`prod-build.yaml`. Cloud Run mounts the secrets automatically at deploy
time — no code changes or extra dependencies needed.

```yaml
_RUNTIME_SECRETS: 'ES_API_KEY=es-api-key:latest,/app/secrets/hash/hashstore.json=hashstore-json:latest'
```

The format is a comma-separated list of `TARGET=SECRET_NAME:VERSION`:
- **Environment variable:** `ES_API_KEY=es-api-key:latest` — mounts as
  env var `ES_API_KEY`, read with `os.environ["ES_API_KEY"]`
- **File mount:** `/app/secrets/hash/hashstore.json=hashstore-json:latest`
  — mounts as a file at that path, read with `open()`

**Option B — Secret Manager API:**

Fetch secrets in your application code at startup. The runtime SAs
(`svc-ai-platform@dev` and `svc-ai-platform@prd`) already have
project-level `secretmanager.secretAccessor` on OPS, so no additional
IAM is needed — just create the secret and fetch it.

```python
from google.cloud import secretmanager

def get_secret(secret_id, project="rsr-ds-group-ops-d0b0"):
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{project}/secrets/{secret_id}/versions/latest"
    return client.access_secret_version(name=name).payload.data.decode("utf-8")

# Example usage at startup
ES_API_KEY = get_secret("es-api-key")
```

Add `google-cloud-secret-manager` to `requirements.txt`.

Both options use the same OPS secrets. Option A is simpler (no code, no
dependency) and the secret value is available immediately. Option B is
useful if you need to refresh secrets without redeploying.

### 1.4 CODEOWNERS

Copy the CODEOWNERS file from this repo into your service:

```bash
cp -r /path/to/rsr-ds-gcp/templates/.github .github
```

### 1.5 Build yamls

Copy the templates from this repo into your service at `deploy/`:

- **Standard service (no GPU):** copy from `templates/deploy/`
- **GPU service (nvidia-l4):** copy from `templates/deploy-gpu/`

Open each file and review the substitutions at the top:

| Substitution | Default | When to change |
|-------------|---------|----------------|
| `_SERVICE_NAME` | `CHANGE_ME` | **Always** — set to your service name |
| `_REGION` | `us-east1` | If co-locating with a dependency (e.g. `europe-west1`) |
| `_MEMORY` | `512Mi` | If loading heavy models at startup (e.g. `16Gi`) |
| `_CPU` | `1` | Must match memory — see limits below |
| `_TIMEOUT` | `300` | If startup takes more than 5 min (e.g. `1800` = 30 min) |
| `_STARTUP_PROBE_THRESHOLD` | `30` | Startup probe failure threshold (× 10s). Increase for slow startup (e.g. `180` = 30 min) |
| `_GCS_BUCKET` | `''` | GCS bucket for large data files (see §1.2). Leave empty if none |
| `_GCS_DIRECTORIES` | `''` | Comma-separated dirs to download from bucket (e.g. `'models,geojsonMaps,data'`) |

**Cloud Run memory/CPU limits:**

| CPU | Max memory |
|-----|-----------|
| 1 | 4Gi |
| 2 | 8Gi |
| 4 | 16Gi |
| 8 | 32Gi |

### 1.6 requirements.txt

List your runtime Python dependencies. The CI test step runs in a plain
`python:3.11` container (not your Docker image), so it installs these
before running tests.

### 1.7 requirements-test.txt

```
pytest
pytest-cov
```

### 1.8 .gitignore

```
__pycache__/
*.pyc
.pytest_cache/
.ruff_cache/
.env
```

Add any service-specific entries (e.g. `*.gguf`, `models/`, large data files).

### 1.9 .dockerignore

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
integration_tests/
deploy/
archive/
```

### 1.10 Pre-flight: lint, test, and scan locally

CI will reject your first push if lint or tests fail. Run these checks before
pushing — they work on Mac, Linux, and Windows:

```bash
pip install ruff pytest pytest-cov detect-secrets

# Lint
ruff check . --exclude archive/

# Test
pytest tests/

# Scan for hardcoded secrets (API keys, passwords, tokens)
detect-secrets scan --all-files .

# Check for files over 10 MB (should not be committed — upload to GCS instead)
python3 -c "import os; [print(f'{os.path.getsize(os.path.join(r,f))/1e6:.1f}MB {os.path.join(r,f)}') for r,d,fs in os.walk('.') for f in fs if os.path.getsize(os.path.join(r,f))>10_000_000 and '.git' not in r]"
```

If `detect-secrets` finds anything, move those values to Secret Manager
(see 1.3). If the file size check finds anything, upload the file to GCS
and download it at startup instead of committing it (see 1.2).

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
# Navigate to your service folder
cd /path/to/rsr-ds-{service}

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

## 4. Create Build Service Account (Terraform)

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
      build_secrets = ["secret-name"]        # see 1.3 — omit if none
      iap           = true                  # see IAP below (frontend services only)
      sync_tables   = []
    }
  }
}
```

### Build groups

Services share a build SA by group. All services in the same group use
`svc-build-{group}@ops`. IAM bindings are requested once per group — if the
group already exists, no new IAM request is needed.

| Group | Purpose | Services |
|-------|---------|----------|
| `ollama` | LLM backed services | ollama, cleanpii, rascoeditorllm |
| `talent` | Talent Radar | taxonomy, digitaltwin |
| `analysis` | Other analysis | sociallistening, qamonitoring, mrapipeline, etc. |

Pick the group that fits your service. If none fits, create a new group name —
Terraform will create the SA automatically, and you'll need to request IAM
bindings for it (Step 5).

### Optional fields

**`region`** — Cloud Run / AR region. Defaults to `us-east1`. Set this if your
service needs a specific region (e.g. co-locate with a dependency, or GPU
availability):

```hcl
{service} = {
  repo        = "rsr-ds-{service}"
  build_group = "ollama"
  region      = "europe-west1"       # co-locate with ollama
  iap         = true                 # frontend services only
  sync_tables = []
}
```

**`iap`** — set to `true` for frontend/UI services that users access in a
browser. The deploy pipeline will automatically enable IAP (Identity-Aware
Proxy) on the Cloud Run service after each deploy. Omit or set to `false` for
backend APIs.

**`build_secrets`** — list of OPS Secret Manager secret IDs the build SA needs
access to at build time (e.g. `hf-token` for HuggingFace downloads). Terraform
grants `secretmanager.secretAccessor` on each secret to the group's build SA.
Omit if your build doesn't need any secrets. Runtime secrets are not managed
by Terraform — see 1.3 for both build-time and runtime secrets.

**`sync_tables`** — BigQuery tables to sync from DEV to PRD. Use
`sync_tables = []` if your service has no BQ tables.

```hcl
{service} = {
  ...
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
- The new SA needs IAM bindings from the infra team — see Step 5

Terraform always creates:
- Cloud Build triggers (dev + prod) for this service

---

## 5. Request IAM Bindings from Infra Team

Submit a single
[GCP Requests](https://randstadglobal.service-now.com/motion?id=sc_cat_item&sys_id=c1b08a2587285510691d62480cbb3584&referrer=popular_items)
ticket in ServiceNow with the applicable CSV(s) below.

### Build SA bindings

> **Skip this** if your service's `build_group` SA already has IAM bindings
> (i.e. another service in the same group was onboarded before).

The build SA needs cross-project permissions that are managed by the infra team
(not Terraform). Copy `templates/iam_request_builder.csv` and replace
`{service}` with your build group name.

### User access bindings

> **Skip this** if the group already has `run.invoker` on DEV and PRD
> (i.e. another service already requested access for this group). The DS team already has access.

Any Google Group that needs to call your service (via API or browser) needs
IAM bindings. Copy `templates/iam_request_user.csv` and replace
`{google-group}` with the group name (e.g.
`gcp-rsr-ds-group-ops@randstadservices.com`). Submit once per group that
needs access.

The template grants two roles on both DEV and PRD:
- `roles/run.invoker` — required for any group calling the Cloud Run service
- `roles/iap.httpsResourceAccessor` — required for groups accessing a
  frontend/UI service through IAP (can be omitted for backend-only APIs)

---

## 6. Connect Repo to Cloud Build

Before triggers can reference your repo, it must be connected to the Cloud Build
GitHub App in the OPS project.

1. Go to **Cloud Build → Repositories (1st gen)** in the OPS project:
   https://console.cloud.google.com/cloud-build/triggers;region=global/connect?project=rsr-ds-group-ops-d0b0
2. Click **Connect Repository**
3. **Region:** Global
4. **Source:** GitHub (Cloud Build GitHub App)
5. Under **Repository**, if your repo doesn't appear, click **"Edit Repositories on GitHub"**
6. Select your repo (`rsr-ds-{service}`) and click **"Update Access"**
7. Back in Connect repository, select the repo and confirm the connection
8. Click **Done**

---

## 7. Initial Deploy

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

### Enable IAP (frontend services only)

> **Skip this** if your service is a backend API with no browser-facing UI.

After the DEV deploy completes, configure IAP with the project's custom
OAuth client so users can access the UI via browser:

1. Go to **Security → Identity-Aware Proxy** in the DEV project:
   https://console.cloud.google.com/security/iap?project=rsr-ds-group-dev-f193
2. Find your Cloud Run service in the list
3. Click the three dots → **Edit OAuth client**
4. Select **Custom OAuth** and enter the project's OAuth client ID and secret
   (see the project's **APIs & Services → Credentials** page)
5. Toggle IAP **on** for the service

The DS Team has a External Auth on DEV and PRD already, but if you deploy in a different project and it doens't have a have an External OAuth client yet, create one first:

1. Go to **Auth → Clients** in the project console
2. Create a new **Web application** OAuth client
3. Set the OAuth consent screen to **External** type, **Testing** mode
4. Add test users (individual emails — groups not supported in Testing mode)

Users must be on the OAuth consent screen's **test users list** to access
IAP-protected services. All DS team members are already added on DEV and PRD.
If a new user needs access, add their email under **Auth → Overview → Test users**
in the project console.

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

For frontend services, repeat the IAP OAuth configuration on the PRD project
(same steps as DEV above, using the PRD project's OAuth client):
https://console.cloud.google.com/security/iap?project=rsr-ds-group-prd-83ad

### Verify PRD

Perform smoke tests against the PRD deployment to confirm everything is
working correctly in production.

---

## 8. Configure Repo Settings

Now that the initial deploy is done and the first build has run, configure
the repo settings to enforce code review and squash merging.

### Merge strategy

Go to **Settings → General → Pull Requests** on the GitHub repo:

- Uncheck **"Allow merge commits"**
- Uncheck **"Allow rebase merging"**
- Keep **"Allow squash merging"** checked

### Branch ruleset

Go to **Settings → Rules → Rulesets → New ruleset → New Branch ruleset**:

- **Ruleset Name:** `main-protection`
- **Enforcement status:** Active
- **Target branches:** Add Target → Include by Pattern → `main` → Add Inclusion pattern
- **Require a pull request before merging:** Yes
  - **Require approvals:** 1 (or your team's preference)
  - **Require review from Code Owners:** Yes
- **Require status checks to pass:** Yes
  - Click **"Add checks"**, search for `{service}-pr` and select the
    entry that includes the project ID:
    `{service}-pr (rsr-ds-group-ops-d0b0)`. Cloud Build appends the
    project ID to the check name — the short name won't match.

Save the ruleset.

From now on, PRs to `main` must be approved and pass the Cloud Build check
before merging. Direct pushes to `main` are blocked.

---

## 9. Celebrate

You're done. Your service is live in production with a full CI/CD pipeline.
