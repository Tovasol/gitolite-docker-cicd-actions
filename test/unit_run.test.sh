#!/usr/bin/env bash
# Unit tests for the manual-run job selection in run-group's process_build:
#   * event 'run' bypasses PATH filters (a manual run targets a version, not a diff)
#   * --job (onlyjob) force-runs exactly that job, skipping branch/path filters
#   * a real 'push' still applies path filters
# execute_job is overridden to just record which jobs would run (no docker needed).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/harness.sh"
export CICD_BASE="$HERE/.."
# shellcheck source=/dev/null
. "$HERE/../bin/run-group.sh"     # _CICD_MAIN=0 -> functions only

W="$(mktemp -d)"
INC="$W/inc"; mkdir -p "$INC"
group="tovasol/app/main"; branch="main"; RUNS="$W/runs"; ENVS="$W/envs"
src="$W/src"; mkdir -p "$src/.gitolite"
cat > "$src/.gitolite/ci.yml" <<'YML'
version: 1
jobs:
  smoke:
    on: { push: { branches: [main] } }
    run: sh ci/smoke.sh
  deploy-site:
    on: { push: { branches: [main], paths: ["site/**"] } }
    run: sh ci/deploy.sh
YML
printf 'README.md\n' > "$INC/SHA.changed"      # changed = README only (NOT under site/**)

# stub the parts that need docker / env state
RAN="$W/ran"
execute_job() { printf '%s\n' "$1" >> "$RAN"; }   # record job name only
persist_env_for_teardown() { :; }
key_loaded() { return 0; }

pb() {  # <event> [onlyjob] -> sorted space-joined jobs that ran
  ( cd "$src" && tar -cf "$INC/SHA.tar" . )       # re-create (process_build consumes it)
  : > "$RAN"
  process_build "$1" SHA 0 tester "${2:-}" >/dev/null 2>&1 || true
  printf '%s ' "$(sort -u "$RAN" 2>/dev/null | tr '\n' ' ')" | sed 's/  */ /g; s/ $//'
}

suite "process_build manual run / job filter"
assert_eq "push: path filter drops deploy-site (README not site/**)" "$(pb push)"          "smoke"
assert_eq "run: paths bypassed -> both branch-matching jobs"         "$(pb run)"            "deploy-site smoke"
assert_eq "run --job deploy-site: force just that one"               "$(pb run deploy-site)" "deploy-site"
assert_eq "run --job smoke: force just that one"                     "$(pb run smoke)"       "smoke"

rm -rf "$W"
summary
