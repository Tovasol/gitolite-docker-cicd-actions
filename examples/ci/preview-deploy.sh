#!/usr/bin/env sh
# Preview deploy (create-or-update) — one isolated env per branch.
# Idempotent: safe to run on both `create` and every `push`.
# Cloudflare Pages auto-creates a per-branch preview alias from --branch.
set -eu
. /cicd/lib.sh
trap 'rc=$?; [ $rc -eq 0 ] && notify_success "preview up: ${CI_BRANCH} -> ${URL:-?}" \
                          || notify_error "preview deploy FAILED (rc=$rc) ${CI_BRANCH}"' EXIT

cd site/scaffold
step "install + build"
retry -n 3 -d 10 -- npm ci --prefer-offline
npm run build

# deterministic per-branch alias from the slug the runner computed
ALIAS="${CI_BRANCH_SLUG:-preview}"
step "deploy preview ($ALIAS)"
retry -n 2 -d 15 -- npx wrangler pages deploy dist --project-name=pipelineforge-site --branch="$ALIAS"

URL="https://${ALIAS}.pipelineforge-site.pages.dev"

# persist what we provisioned so teardown knows what to destroy (DESIGN §14).
# CI_ENV_DIR is a host-side dir bind-mounted at /envstate, surviving branch deletion.
cat > "${CI_ENV_DIR:-/envstate}/state" <<EOF
pages_project=pipelineforge-site
pages_alias=$ALIAS
url=$URL
last_sha=${CI_SHA:-}
EOF

echo "preview up: $URL"
