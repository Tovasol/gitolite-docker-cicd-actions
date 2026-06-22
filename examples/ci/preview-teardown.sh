#!/usr/bin/env sh
# Preview teardown — runs on branch delete.
# The deleted branch's FULL tree is restored at /work (cwd) via the preservation
# ref, so you may reference any project file here (infra/, compose, terraform…).
# Runtime state from preview-deploy.sh is mounted at $CI_ENV_DIR (/envstate).
# In the rare fallback (no preserve ref) cwd is /envstate with only ci/ + state.
# Must be idempotent (exit 0 if nothing exists).
# Secrets: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID.
set -eu
. /cicd/lib.sh
# retry on transient API errors is the SCRIPT's job now (was a manifest field).
trap 'rc=$?; [ $rc -eq 0 ] && notify_success "torn down preview ${CI_BRANCH}" \
                          || notify_error "teardown FAILED (rc=$rc) ${CI_BRANCH} — see ci-status"' EXIT

STATE="${CI_ENV_DIR:-/envstate}/state"
[ -f "$STATE" ] || { echo "no state for ${CI_BRANCH:-?} — nothing to tear down"; exit 0; }
# shellcheck disable=SC1091
. "$STATE"

step "delete preview deployments for ${pages_alias:-}"
delete_previews() {   # idempotent: already-gone is fine
  npx wrangler pages deployment list --project-name="${pages_project:-pipelineforge-site}" 2>/dev/null \
  | awk -v a="${pages_alias:-}" 'a != "" && $0 ~ a {print $1}' \
  | xargs -r -n1 npx wrangler pages deployment delete --yes >/dev/null 2>&1
}
retry -n 3 -d 10 -- delete_previews     # retry the network call (the SCRIPT owns retry)

# free any other per-branch resources here (DNS, container, DB schema, port)…
