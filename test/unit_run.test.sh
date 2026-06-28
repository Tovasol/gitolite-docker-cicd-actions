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

suite "clamp_timeout (job timeout can't disable the wall-clock kill)"
DEFAULT_TIMEOUT=900; TIMEOUT_MAX=86400
assert_eq "normal value passes through"        "$(clamp_timeout 600)"          "600"
assert_eq "empty -> default"                   "$(clamp_timeout '')"           "900"
assert_eq "zero -> default (would disable)"    "$(clamp_timeout 0)"            "900"
assert_eq "leading-zero zero -> default"       "$(clamp_timeout 00)"           "900"
assert_eq "non-numeric -> default"             "$(clamp_timeout 'sleep')"      "900"
assert_eq "suffix form rejected -> default"    "$(clamp_timeout '10m')"        "900"
assert_eq "absurd value capped at MAX"         "$(clamp_timeout 999999999999)" "86400"
assert_eq "exactly MAX allowed"                "$(clamp_timeout 86400)"        "86400"

suite "secret redaction (build_mask_script + redact_log)"
ENVF="$W/env"; MASK="$W/mask"
cat > "$ENVF" <<'DOTENV'
# a comment line is ignored
CLOUDFLARE_API_TOKEN=supersecrettoken123
SHORT=ab
QUOTED="quoted-secret-value"
WITH_SLASH=aa/bb/cc/dd
DOTENV
build_mask_script "$ENVF" "$MASK"
masked="$(printf 'tok=supersecrettoken123 q=quoted-secret-value s=aa/bb/cc/dd end\n' | redact_log "$MASK")"
assert_no_match "long token masked"        "$masked" 'supersecrettoken123'
assert_no_match "quoted value masked"      "$masked" 'quoted-secret-value'
assert_no_match "value with slashes masked" "$masked" 'aa/bb/cc/dd'
assert_match    "MASKED marker present"    "$masked" 'MASKED'
# short value (<6) is NOT masked — would corrupt logs by masking common tokens
notmasked="$(printf 'label ab here\n' | redact_log "$MASK")"
assert_match    "short value left intact"  "$notmasked" 'label ab here'
# no maskfile (no secrets) -> passthrough unchanged
assert_eq "absent maskfile -> passthrough" "$(printf 'nothing secret\n' | redact_log /no/such/file)" "nothing secret"

rm -rf "$W"
summary
