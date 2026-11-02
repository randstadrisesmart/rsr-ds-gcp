#!/usr/bin/env bash
# Delete Artifact Registry images nothing references. Inlined into the
# artifact-registry-cleanup Cloud Build trigger by artifact-registry-cleanup.tf;
# see that file for the rule and the safety contract.
#
# Env: DRY_RUN (true|false), PROJECTS (space-separated), REPOS (space-separated),
#      MIN_AGE_H (hours). Every listing failure aborts the run before any delete.
set -euo pipefail

: "${DRY_RUN:?}" "${PROJECTS:?}" "${REPOS:?}" "${MIN_AGE_H:?}"

WORK=$(mktemp -d)
REF="$WORK/referenced.txt"     # one "<image-path>@sha256:..." per line
INV="$WORK/inventory.txt"      # "<image-path>@sha256:...|<tags>|<createTime>" per line
: > "$REF"; : > "$INV"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# A listing that returns nothing where something must exist is a failure, not
# an empty result; it would otherwise widen the deletion set silently.
must_nonempty() { # file, what
  if [ ! -s "$1" ]; then echo "ABORT: $2 produced no rows" >&2; exit 2; fi
}

# ── 1. referenced: every image pinned by a Cloud Run revision or job ──────────
for P in $PROJECTS; do
  REGIONS=$(gcloud run regions list --project="$P" --format="value(locationId)")
  [ -n "$REGIONS" ] || { echo "ABORT: no Cloud Run regions listed for $P" >&2; exit 2; }
  for R in $REGIONS; do
    gcloud run revisions list --project="$P" --region="$R" \
      --format="value(spec.containers[].image)" >> "$REF"
    gcloud run jobs list --project="$P" --region="$R" \
      --format="value(spec.template.spec.template.spec.containers[].image)" >> "$REF"
  done
done
# Flatten "a;b" multi-container cells, drop images outside our registries.
sed -i 's/;/\n/g' "$REF"
grep -E '^[a-z0-9-]+-docker\.pkg\.dev/' "$REF" | sort -u > "$REF.ours" || true
must_nonempty "$REF" "Cloud Run revision/job listing"
log "referenced images in Cloud Run: $(wc -l < "$REF.ours") (of $(sort -u "$REF" | wc -l) distinct)"

# Tag references (e.g. jobtitle-normalizer:140fc82) resolve to the digest that
# carries the tag right now. A tag that no longer resolves is a dangling
# reference, reported and ignored.
: > "$REF.digests"
while read -r IMG; do
  case "$IMG" in
    *@sha256:*) echo "$IMG" >> "$REF.digests" ;;
    *:*)
      D=$(gcloud artifacts docker images describe "$IMG" --format="value(image_summary.digest)" 2>/dev/null || true)
      if [ -n "$D" ]; then echo "${IMG%%:*}@$D" >> "$REF.digests"
      else log "WARN dangling tag reference (already gone): $IMG"; fi ;;
    *) log "WARN untagged reference treated as :latest: $IMG"
       D=$(gcloud artifacts docker images describe "$IMG:latest" --format="value(image_summary.digest)" 2>/dev/null || true)
       [ -n "$D" ] && echo "$IMG@$D" >> "$REF.digests" ;;
  esac
done < "$REF.ours"
sort -u "$REF.digests" -o "$REF.digests"
must_nonempty "$REF.digests" "referenced digest set"
log "referenced digests: $(wc -l < "$REF.digests")"

# ── 2. inventory: every version in the in-scope repos ────────────────────────
NOW=$(date -u +%s)
for P in $PROJECTS; do
  for LOC in $(gcloud artifacts repositories list --project="$P" \
                 --format="value[separator='/'](name.segment(3),name.basename())"); do
    REPO=${LOC#*/}; REGION=${LOC%/*}
    case " $REPOS " in *" $REPO "*) ;; *) continue ;; esac
    ROOT="$REGION-docker.pkg.dev/$P/$REPO"
    gcloud artifacts docker images list "$ROOT" --include-tags \
      --format="csv[no-heading,separator='|'](package,version,tags,createTime)" \
      | awk -F'|' -v OFS='|' '{ gsub(/"/,"",$3); print $1"@"$2, $3, $4 }' >> "$INV"
    log "inventory $ROOT: $(grep -c "^$ROOT/" "$INV" || true) versions"
  done
done
must_nonempty "$INV" "Artifact Registry image listing"

# ── 3. decide ────────────────────────────────────────────────────────────────
: > "$WORK/delete.txt"; : > "$WORK/keep.txt"
while IFS='|' read -r IMG TAGS CREATED; do
  [ -n "$IMG" ] || continue
  AGE_H=$(( (NOW - $(date -u -d "$CREATED" +%s)) / 3600 ))
  if grep -qxF "$IMG" "$REF.digests"; then
    echo "$IMG|cloud-run" >> "$WORK/keep.txt"
  elif [[ ",$TAGS," == *",latest,"* ]]; then
    echo "$IMG|latest-tag" >> "$WORK/keep.txt"
  elif [ "$AGE_H" -lt "$MIN_AGE_H" ]; then
    echo "$IMG|younger-than-${MIN_AGE_H}h" >> "$WORK/keep.txt"
  else
    echo "$IMG|${TAGS:-untagged}|${AGE_H}h" >> "$WORK/delete.txt"
  fi
done < "$INV"

N_KEEP=$(wc -l < "$WORK/keep.txt"); N_DEL=$(wc -l < "$WORK/delete.txt")
log "keep $N_KEEP  ($(grep -c '|cloud-run$' "$WORK/keep.txt") cloud-run, $(grep -c '|latest-tag$' "$WORK/keep.txt") latest, $(grep -c 'younger' "$WORK/keep.txt") too young)"
log "delete $N_DEL"
echo "----- DELETE LIST (image|tags|age) -----"; cat "$WORK/delete.txt"; echo "-----"

# Paranoia: every image a serving service runs must be in the keep set.
if [ "$(grep -c '|cloud-run$' "$WORK/keep.txt")" -eq 0 ]; then
  echo "ABORT: no Cloud Run-referenced image found in inventory; refusing to delete" >&2; exit 2
fi

# ── 4. delete ────────────────────────────────────────────────────────────────
if [ "$DRY_RUN" != "false" ]; then
  log "DRY_RUN=$DRY_RUN: nothing deleted. Set artifact_registry_cleanup_dry_run=false in Terraform to enable."
  exit 0
fi
# Deletes are issued --async. Synchronous gcloud polls the operation and that
# poll fails spuriously (PERMISSION_DENIED on an operation that has already
# finished, first run 2026-11-02) and takes ~5 s per image, which blew the
# build timeout. The request is the only thing gcloud is trusted on here;
# success is verified below by re-listing the repos.
FAILED_REQ=0
while IFS='|' read -r IMG _; do
  if ! gcloud artifacts docker images delete "$IMG" --delete-tags --async --quiet >/dev/null 2>"$WORK/err"; then
    log "ERROR delete request rejected for $IMG: $(tr '\n' ' ' < "$WORK/err")"; FAILED_REQ=$((FAILED_REQ+1))
  fi
done < "$WORK/delete.txt"
log "delete requests issued: $((N_DEL-FAILED_REQ)) accepted, $FAILED_REQ rejected"

# Verify: re-inventory and intersect with the delete list, retrying while the
# async deletes drain. Anything still present at the deadline is a failure.
cut -d'|' -f1 "$WORK/delete.txt" | sort -u > "$WORK/delete.imgs"
DEADLINE=$(( $(date -u +%s) + 1800 ))
while :; do
  : > "$WORK/now.txt"
  for P in $PROJECTS; do
    for LOC in $(gcloud artifacts repositories list --project="$P" \
                   --format="value[separator='/'](name.segment(3),name.basename())"); do
      REPO=${LOC#*/}; REGION=${LOC%/*}
      case " $REPOS " in *" $REPO "*) ;; *) continue ;; esac
      gcloud artifacts docker images list "$REGION-docker.pkg.dev/$P/$REPO" \
        --format="csv[no-heading,separator='|'](package,version)" \
        | awk -F'|' '{ print $1"@"$2 }' >> "$WORK/now.txt"
    done
  done
  must_nonempty "$WORK/now.txt" "post-delete image listing"
  sort -u "$WORK/now.txt" -o "$WORK/now.txt"
  comm -12 "$WORK/delete.imgs" "$WORK/now.txt" > "$WORK/remaining.txt"
  N_REM=$(wc -l < "$WORK/remaining.txt")
  log "verify: $N_REM of $N_DEL still present"
  [ "$N_REM" -eq 0 ] && break
  [ "$(date -u +%s)" -lt "$DEADLINE" ] || break
  sleep 60
done
log "done: $((N_DEL-N_REM)) deleted, $N_REM still present"
if [ "$N_REM" -gt 0 ]; then
  echo "----- NOT DELETED -----"; cat "$WORK/remaining.txt"; echo "-----"
  exit 1
fi
