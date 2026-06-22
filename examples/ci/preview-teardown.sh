#!/usr/bin/env sh
# Preview teardown — runs on branch delete.
# The deleted branch's FULL tree is restored at /work (cwd) via the preservation
# ref, so you may reference any project file here (infra/, compose, terraform…).
# Runtime state from preview-deploy.sh is mounted at $CI_ENV_DIR (/envstate).
# In the rare fallback (no preserve ref) cwd is /envstate with only ci/ + state.
# Must be idempotent (exit 0 if nothing exists).
# Secrets: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID.
set -eu

STATE="${CI_ENV_DIR:-/envstate}/state"
[ -f "$STATE" ] || { echo "no state for ${CI_BRANCH:-?} — nothing to tear down"; exit 0; }
# shellcheck disable=SC1091
. "$STATE"

# delete this branch's preview deployments (idempotent; ignore if already gone)
npx wrangler pages deployment list --project-name="${pages_project:-pipelineforge-site}" 2>/dev/null \
  | awk -v a="${pages_alias:-}" 'a != "" && $0 ~ a {print $1}' \
  | xargs -r -n1 npx wrangler pages deployment delete --yes >/dev/null 2>&1 || true

# free any other per-branch resources here (DNS, container, DB schema, port)…

echo "torn down preview for ${CI_BRANCH:-?} (${pages_alias:-})"
