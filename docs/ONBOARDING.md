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
- External credentials, API keys, or secrets must be stored in **Secret
  Manager** — no hardcoded strings (see Step 4b for details)

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
| `_MEMORY` | `512Mi` | If loading heavy models at startup (e.g. `16Gi`) |
| `_CPU` | `1` | Must match memory — see limits below |
| `_TIMEOUT` | `300` | If startup takes more than 5 min (e.g. `1800` = 30 min) |

**Cloud Run memory/CPU limits:**

| CPU | Max memory |
|-----|-----------|
| 1 | 4Gi |
| 2 | 8Gi |
| 4 | 16Gi |
| 8 | 32Gi |

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
      build_secrets = ["name"]              # see Build Secrets below
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
Omit if your build doesn't need any secrets.

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

## 4b. Runtime Secrets

If your service needs secrets at **runtime** (API keys, encryption keys,
credentials used while handling requests), they go in each project's Secret
Manager (DEV and PRD) — not OPS. This is because Cloud Run resolves
`--update-secrets` references from the project the service is deployed in.

> **Build secrets vs runtime secrets:**
> - **Build secrets** (`build_secrets` in `services.tf`) live in OPS and are
>   available during `docker build` — e.g. `hf-token` to download models.
> - **Runtime secrets** live in DEV and PRD and are mounted on the running
>   Cloud Run container — e.g. API keys, encryption keys, database credentials.

### How we did it (sociallistening example)

We created the same secrets in both DEV and PRD, then granted the runtime SA
access and added `--update-secrets` to the deploy yamls.

### Step-by-step

**1. Create the secret in DEV and PRD:**

```bash
# As an env var (e.g. API key)
echo -n "your-secret-value" | gcloud secrets create {secret-name} \
  --project=rsr-ds-group-dev-f193 --data-file=- --replication-policy=automatic

# Or from a file (e.g. JSON key file)
gcloud secrets create {secret-name} \
  --project=rsr-ds-group-dev-f193 --data-file=/path/to/file.json \
  --replication-policy=automatic

# Repeat for PRD
# ... --project=rsr-ds-group-prd-83ad ...
```

**2. Grant the runtime SA access in each project:**

```bash
gcloud secrets add-iam-policy-binding {secret-name} \
  --project=rsr-ds-group-dev-f193 \
  --member="serviceAccount:svc-ai-platform@rsr-ds-group-dev-f193.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# Repeat for PRD with the PRD SA and project
```

**3. Add `--update-secrets` to the deploy step in your build yamls:**

Secrets can be mounted as **env vars** or **files**:

```yaml
# As an env var — app reads os.environ['MY_API_KEY']
- '--update-secrets=MY_API_KEY=my-api-key:latest'

# As a file — app reads from the mount path
# IMPORTANT: Cloud Run allows only ONE secret per directory.
# If you have multiple file secrets, mount each in its own subdirectory.
- '--update-secrets=/app/secrets/a/keyfile.json=keyfile-secret:latest,/app/secrets/b/other.json=other-secret:latest'
```

### Constraints

- `--update-secrets` only resolves secrets from the **same project** as the
  Cloud Run service. Cross-project references (e.g. `projects/other-project/secrets/...`)
  are not supported in the shorthand syntax.
- Cloud Run allows only **one secret per mount directory**. If you need multiple
  file-mounted secrets, put each in its own subdirectory.
- The secret value can be updated in Secret Manager without redeploying — the
  next container instance will pick up the latest version (if using `:latest`).

### Alternative approaches

| Approach | Pros | Cons |
|----------|------|------|
| **Per-project secrets (what we do)** | Simple `--update-secrets` syntax, works with Cloud Run natively, secrets updateable without redeploy | Must create and maintain secrets in both DEV and PRD |
| **Fetch from OPS at runtime via API** | Single source of truth in OPS, no duplication | Requires code changes (`secretmanager.SecretManagerServiceClient`), adds latency at startup, runtime SA needs cross-project IAM |
| **Env vars in deploy yaml** | Simplest to set up | Values visible in Cloud Run console and build logs, not rotatable without redeploy |
| **Bake into Docker image** | No Secret Manager needed | Secrets in image layers, visible to anyone with AR access, not rotatable |

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

Any Google Group that needs to call your service (via API or browser) needs
IAM bindings. Copy `templates/iam_request_user.csv` and replace
`{google-group}` with the group name (e.g.
`gcp-rsr-ds-group-ops@randstadservices.com`). Submit once per group that
needs access. The DS Team already has access.

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
7. Back in Connect repositoy, select the repo and confirm the connection
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
  - Click **"Add checks"**, search for `{service}-pr` and select it

Save the ruleset.

From now on, PRs to `main` must be approved and pass the Cloud Build check
before merging. Direct pushes to `main` are blocked.

---

## 9. Celebrate

You're done. Your service is live in production with a full CI/CD pipeline.
