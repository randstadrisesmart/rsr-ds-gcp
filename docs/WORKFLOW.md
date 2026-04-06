# Day-to-Day Development Workflow

How to make changes, get them reviewed, and deploy to DEV and PRD.

This assumes your service is already onboarded (see `ONBOARDING.md`).

Replace `{service}` with your service name throughout.

---

## How CI/CD Works

There are three Cloud Build triggers per service:

| Trigger | Fires when | What it does |
|---------|-----------|--------------|
| `{service}-pr` | PR opened/updated against `main` | Runs tests + lint (validation only, no deploy) |
| `{service}-dev` | Push to `main` (i.e. PR merged) | Tests + lint + build image + deploy to DEV |
| `{service}-prd` | Tag matching `{service}-vX.X.X` | Copies DEV image to PRD + deploys (requires manual approval) |

You never deploy manually. Merging to `main` deploys to DEV. Tagging deploys to PRD.

---

## Making a Change

### 1. Create a feature branch

Always start from an up-to-date `main`:

```bash
# Switch to main and pull latest
git checkout main
git pull

# Create a new branch for your work
# Naming convention: feature-{service}-{short-description}
git checkout -b feature-{service}-add-caching
```

`git checkout -b` creates a new branch and switches to it in one command.

### 2. Make your changes

Edit code, add tests, update requirements if needed. Run tests locally
to catch issues early:

```bash
pip install -r requirements.txt -r requirements-test.txt
pytest tests/
```

### 3. Commit your changes

```bash
# See what files changed
git status

# Stage the files you want to commit
git add server.py tests/test_server.py

# Commit with a descriptive message
git commit -m "Add response caching for taxonomy lookups"
```

Tips:
- `git add .` stages everything — use with care, check `git status` first
- Keep commits focused on one change
- Write commit messages that explain *why*, not just *what*

### 4. Pre-flight: lint, test, and scan locally

CI will reject your PR if any of these fail. Run them before pushing to
save a round-trip:

```bash
# Lint
ruff check . --exclude archive/

# Test
pytest tests/ -v

# Scan for hardcoded secrets (API keys, passwords, tokens)
detect-secrets scan --all-files .

# Check for files over 10 MB (should not be committed — upload to GCS instead)
python3 -c "import os; [print(f'{os.path.getsize(os.path.join(r,f))/1e6:.1f}MB {os.path.join(r,f)}') for r,d,fs in os.walk('.') for f in fs if os.path.getsize(os.path.join(r,f))>10_000_000 and '.git' not in r]"
```

If `detect-secrets` flags false positives (e.g. the word "secret" in a
variable name), update your `.secrets.baseline` file — see `ONBOARDING.md` §1.10.

### 5. Push your branch

```bash
# First push: -u sets up tracking so future pushes just need 'git push'
git push -u origin feature-{service}-add-caching

# Subsequent pushes to the same branch:
git push
```

### 5. Open a Pull Request

**Option A — from the CLI:**

```bash
gh pr create --title "Add response caching for taxonomy lookups" \
  --body "What: Added caching layer for taxonomy API responses.
Why: Reduces redundant lookups and improves response times."
```

**Option B — from the GitHub UI:**

Go to GitHub — you'll see a banner to create a PR. Click it, or go to:
https://github.com/randstadrisesmart/rsr-ds-{service}/pull/new/feature-{service}-add-caching

Fill in:
- **Title:** Short description of the change
- **Description:** What changed and why, any testing notes
- **Reviewers:** Add your team members

The `{service}-pr` trigger runs automatically. You'll see a status check
on the PR — tests + lint must pass before you can merge.

### 6. Merge the PR

Once approved and green:

- Click **"Squash and merge"** (this combines all your commits into one clean commit on `main`)
- Delete the feature branch when prompted

This triggers `{service}-dev` → builds + deploys to DEV automatically.

### 7. Verify the DEV deploy

Check the build in Cloud Build console:
https://console.cloud.google.com/cloud-build/builds?project=rsr-ds-group-ops-d0b0

Filter by trigger name `{service}-dev` to find your build. Green = deployed.

Test your change against the DEV service URL.

---

## Deploying to Production

Production deploys are triggered by git tags and require manual approval.

### 1. Make sure DEV is good

Verify your change works in DEV before promoting to PRD.

### 2. Create a release tag

```bash
# Make sure you're on the latest main
git checkout main
git pull

# Create a version tag
# Convention: {service}-vX.X.X (semantic versioning)
git tag {service}-v1.2.3

# Push the tag to GitHub
git push origin {service}-v1.2.3
```

Version numbering:
- **Major** (v2.0.0): breaking API changes
- **Minor** (v1.3.0): new features, backwards compatible
- **Patch** (v1.2.4): bug fixes

### 3. Approve the build

The `{service}-prd` trigger fires but waits for approval.

Go to Cloud Build console:
https://console.cloud.google.com/cloud-build/builds?project=rsr-ds-group-ops-d0b0

Find the pending build (it will show "Awaiting approval"), click it, and approve.

The build then:
1. Copies the image from DEV Artifact Registry to PRD Artifact Registry
2. Deploys to PRD Cloud Run

### 4. Verify the PRD deploy

Test your change against the PRD service URL. Check Cloud Run metrics
for errors:
https://console.cloud.google.com/run?project=rsr-ds-group-prd-83ad

---

## Hotfix (urgent production fix)

Same process, just faster:

```bash
git checkout main
git pull
git checkout -b feature-{service}-hotfix-description
# make the fix
git add .
git commit -m "Fix: description of the issue"
git push -u origin feature-{service}-hotfix-description
```

Open PR → get a quick review → squash and merge → verify on DEV → tag → approve → PRD.

There's no shortcut to skip DEV. The image that runs in PRD is always the
one that was built and tested in DEV first.

---

## Common Git Commands

| What you want to do | Command |
|---------------------|---------|
| See what files changed | `git status` |
| See the actual changes | `git diff` |
| See changes already staged | `git diff --staged` |
| Undo changes to a file (before staging) | `git checkout -- filename` |
| Unstage a file (keep changes) | `git reset HEAD filename` |
| See recent commits | `git log --oneline -10` |
| Switch to an existing branch | `git checkout branch-name` |
| List all branches | `git branch -a` |
| Delete a local branch | `git branch -d branch-name` |
| Pull latest from remote | `git pull` |
| See which remote your repo points to | `git remote -v` |

---

## Troubleshooting

### PR check failed

Look at the Cloud Build log for the `{service}-pr` build. Common issues:
- **Test failure:** fix the test or the code, push again to the same branch
- **Lint failure:** run `ruff check` locally, fix issues, push again
- **Import error:** missing dependency in `requirements.txt`

Pushing to the same branch automatically re-runs the PR check.

### DEV deploy failed

Check the `{service}-dev` build log. Common issues:
- **Docker build failed:** Dockerfile issue or missing file
- **Deploy failed:** Cloud Run rejected the config (check resource limits, port, etc.)
- **Permission denied:** build SA missing a role — check with infra team

### PRD deploy failed

Check the `{service}-prd` build log. Common issues:
- **Image copy failed:** build SA can't read from DEV AR or write to PRD AR
- **Deploy failed:** same as DEV but check PRD-specific config (min-instances, etc.)

### I need to roll back production

Deploy the previous version's tag again — or find the last good commit SHA
and deploy manually:

```bash
gcloud run deploy {service} \
  --image={region}-docker.pkg.dev/rsr-ds-group-prd-83ad/docker-images/{service}:{previous-commit-sha} \
  --project=rsr-ds-group-prd-83ad \
  --region={region}
```
