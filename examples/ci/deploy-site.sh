#!/usr/bin/env sh
# Production deploy. Runs in node:20-alpine, cwd=/work. Env: CI_*, npm cache at
# /cache/npm. Secrets (CLOUDFLARE_*) injected as env. Retry + notify come from the
# mounted lib — no manifest fields needed.
set -eu
. /cicd/lib.sh

# one notification on exit, success or failure (fires on normal exit + TERM/timeout)
trap 'rc=$?; [ $rc -eq 0 ] && notify_success "deployed main @ ${CI_SHA}" \
                          || notify_error "deploy FAILED (rc=$rc) main @ ${CI_SHA}"' EXIT

cd site/scaffold
step "install deps"
retry -n 3 -d 10 -- npm ci --prefer-offline    # retry the flaky network step only
step "build"
npm run build
step "deploy"
retry -n 2 -d 15 -- npx wrangler pages deploy dist --project-name=pipelineforge-site --branch=main
