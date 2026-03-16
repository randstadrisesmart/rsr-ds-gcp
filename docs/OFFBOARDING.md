# Service Offboarding Guide

Step-by-step guide to remove a service from the CI/CD pipeline and clean up all associated resources.

Replace `{service}` with your service name throughout (e.g. `ollama`, `taxonomy`, `langapi`).

---

## 1. Stop Traffic

Before removing anything, make sure nothing is calling the service.

- Check Cloud Run metrics for recent requests:
  https://console.cloud.google.com/run/detail/{region}/{service}/metrics?project=rsr-ds-group-prd-83ad
- Notify any teams that depend on this service
- If the service has callers, update them to remove calls first

---

## 2. Remove Cloud Build Triggers

Go to Cloud Build in the OPS project:
https://console.cloud.google.com/cloud-build/triggers?project=rsr-ds-group-ops-d0b0

Delete all three triggers for the service:
- `{service}-pr`
- `{service}-dev`
- `{service}-prd`

This stops any future builds from running. Existing deployed services are unaffected.

---

## 3. Remove from Terraform

### Remove the service from services.tf

In the `rsr-ds-gcp` repo, edit `environments/ops/services.tf` and remove the
service entry from `local.services`:

```hcl
locals {
  services = {
    # remove this line:
    # {service} = { repo = "rsr-ds-{service}" }
  }
}
```

### Remove Cloud Run definition (if it exists)

If the service has a module block in `environments/prod/main.tf`, remove it:

```hcl
# remove this block:
# module "{service}" {
#   source = "../../modules/cloud-run-service"
#   ...
# }
```

### Apply the changes

```bash
# Commit and push to dev first
git checkout dev
git add .
git commit -m "Remove {service} from Terraform"
git push origin dev

# Merge to ops to apply — this destroys the build SA, triggers,
# and removes tables from sync VIEWs
git checkout ops
git merge origin/dev
git push origin ops

# If you removed a Cloud Run definition in prod:
git checkout prod
git merge origin/dev
git push origin prod
```

Terraform will destroy:
- Build SA (`svc-build-{service}@ops`)
- PubSub publisher grant
- Cloud Build triggers (if managed by Terraform)
- Sync table VIEW entries (if `sync_tables` was configured)

---

## 4. Request IAM Cleanup from Infra Team

The 8 cross-project IAM bindings for the build SA were created by the infra
team (not Terraform). Submit a ticket to remove them:

**Service account:** `svc-build-{service}@rsr-ds-group-ops-d0b0.iam.gserviceaccount.com`

**DEV (`rsr-ds-group-dev-f193`) — remove:**
- `roles/artifactregistry.writer`
- `roles/artifactregistry.reader`
- `roles/run.admin`
- `roles/iam.serviceAccountUser`

**PRD (`rsr-ds-group-prd-83ad`) — remove:**
- `roles/artifactregistry.writer`
- `roles/run.admin`
- `roles/iam.serviceAccountUser`

**OPS (`rsr-ds-group-ops-d0b0`) — remove:**
- `roles/logging.logWriter`

---

## 5. Delete Cloud Run Services

Delete the service from both environments:

```bash
# Delete from DEV
gcloud run services delete {service} \
  --region={region} \
  --project=rsr-ds-group-dev-f193

# Delete from PRD
gcloud run services delete {service} \
  --region={region} \
  --project=rsr-ds-group-prd-83ad
```

Replace `{region}` with the service's region (e.g. `us-east1` or `us-central1`).

---

## 6. Clean Up Container Images

Remove images from Artifact Registry in both environments:

```bash
# List images to confirm
gcloud artifacts docker images list \
  {region}-docker.pkg.dev/rsr-ds-group-dev-f193/docker-images/{service}

# Delete from DEV AR
gcloud artifacts docker images delete \
  {region}-docker.pkg.dev/rsr-ds-group-dev-f193/docker-images/{service} \
  --delete-tags

# Delete from PRD AR
gcloud artifacts docker images delete \
  {region}-docker.pkg.dev/rsr-ds-group-prd-83ad/docker-images/{service} \
  --delete-tags
```

If the service also has a base image (e.g. GPU services on gcr.io), delete that too:

```bash
gcloud container images delete gcr.io/rsr-ds-group-dev-f193/{service}-base
```

---

## 7. Clean Up BigQuery (if applicable)

If the service had `sync_tables` entries, the sync VIEW was already updated
in Step 3 (Terraform removes the entries). But the actual tables in DEV and
PRD still exist.

Decide whether to keep or delete:
- **Keep** if other services or BI tools still query the data
- **Delete** if the data is no longer needed

To delete:

```bash
# Delete dataset in DEV
bq rm -r -f rsr-ds-group-dev-f193:{dataset_name}

# Delete dataset in PRD
bq rm -r -f rsr-ds-group-prd-83ad:{dataset_name}
```

The `-r` flag deletes all tables in the dataset. The `-f` flag skips
confirmation. Double-check the dataset name before running.

---

## 8. Archive the GitHub Repo

Go to the repo on GitHub → **Settings → General → Danger Zone → Archive this repository**

This makes the repo read-only. It preserves the code and history but prevents
any new pushes, PRs, or issues. You can unarchive later if needed.

Do NOT delete the repo — archived repos are free and the history may be useful.

---

## Checklist

- [ ] Traffic stopped, callers updated
- [ ] Cloud Build triggers deleted
- [ ] Service removed from `services.tf` and `main.tf`
- [ ] Terraform applied on `ops` (and `prod` if applicable)
- [ ] IAM cleanup requested from infra team
- [ ] Cloud Run services deleted (DEV + PRD)
- [ ] Container images deleted (DEV + PRD AR)
- [ ] BigQuery datasets deleted (if applicable)
- [ ] GitHub repo archived
