#!/usr/bin/env bash
# pipeline-dag.sh — COPY-PASTE REFERENCE: a full DAG built in plain bash using the
# /cicd/lib.sh helpers. Shows sequential stages, fan-OUT (parallel), fan-IN (join +
# fail-if-any), per-step retry, conditional branching, rollback, and rich notify.
#
# The runner runs ONE script per job. This script IS the orchestration graph — no
# runner-level job dependencies needed. Point a manifest job at it:
#     run: bash ci/pipeline-dag.sh
# (use bash, not sh, for arrays/`wait -n`; ensure your image has bash, or keep to the
#  POSIX wait_all pattern shown below which works in plain sh too.)
set -euo pipefail
. /cicd/lib.sh

# ── terminal notification: one email at the end, success or failure ───────────
trap 'rc=$?; if [ $rc -eq 0 ]; then notify_success "pipeline OK ${CI_BRANCH} @ ${CI_SHA}";
              else notify_error "pipeline FAILED (rc=$rc) ${CI_BRANCH} @ ${CI_SHA}"; fi' EXIT

# ── stage 1: sequential prep (retry the network-y bits) ───────────────────────
step "prep"
retry -n 3 -d 10 -- npm ci --prefer-offline

# ── stage 2: FAN-OUT — run independent tasks in parallel, collect PIDs ─────────
step "fan-out: lint + test + build in parallel"
pids=""
( npm run lint        > /tmp/lint.log  2>&1 ) & pids="$pids $!"
( npm run test        > /tmp/test.log  2>&1 ) & pids="$pids $!"
( npm run build       > /tmp/build.log 2>&1 ) & pids="$pids $!"

# ── stage 3: FAN-IN — wait for ALL; fail if ANY failed (wait_all from the lib) ─
step "fan-in: join"
if ! wait_all $pids; then
  # surface which leg failed
  for f in lint test build; do
    tail -n 20 "/tmp/$f.log" 2>/dev/null | sed "s/^/[$f] /"
  done
  die "one or more parallel tasks failed"      # notify_error + exit 1
fi
notify "lint+test+build all green"

# ── stage 4: CONDITIONAL branching on event/branch ────────────────────────────
step "deploy decision"
case "$CI_BRANCH" in
  main)
    step "deploy production"
    retry -n 2 -d 15 -- npx wrangler pages deploy dist --project-name=pipelineforge-site --branch=main
    ;;
  *)
    step "deploy preview ($CI_BRANCH_SLUG)"
    retry -n 2 -d 15 -- npx wrangler pages deploy dist --project-name=pipelineforge-site --branch="$CI_BRANCH_SLUG"
    ;;
esac

# ── stage 5: post-deploy verify + rollback on failure (branch on result) ──────
step "smoke test"
if ! retry -n 3 -d 5 -- curl -fsS "https://${CI_BRANCH_SLUG}.pipelineforge-site.pages.dev/healthz" >/dev/null; then
  step "ROLLBACK"
  # ... your rollback command here ...
  die "smoke test failed — rolled back"
fi

# ── fan-out round 2: independent post-deploy hooks (don't fail the deploy) ─────
step "post-deploy hooks (best-effort)"
pids=""
( npx some-cache-purge        || true ) & pids="$pids $!"
( npx ping-uptime-monitor     || true ) & pids="$pids $!"
wait_all $pids || notify "a post-deploy hook failed (non-fatal)"

notify "pipeline complete"
# EXIT trap emits the terminal success/failure email.
