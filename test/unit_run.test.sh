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

suite "secret redaction — multi-line keys materialize real newlines (H6)"
ENVF2="$W/env2"; MASK2="$W/mask2"
# a key stored single-line with literal \n, exactly as `sops -d --output-type dotenv` emits it
printf 'GOOGLE_SA_KEY=-----BEGIN PRIVATE KEY-----\\nMIIabcdeflinetwo123\\nMIItulinethree456\\n-----END KEY-----\n' > "$ENVF2"
build_mask_script "$ENVF2" "$MASK2"
materialized="$(printf '%b' 'MIIabcdeflinetwo123\nMIItulinethree456')"   # what a tool prints (real \n)
masked="$(printf '%s\n' "$materialized" | redact_log "$MASK2")"
assert_no_match "multi-line key line 1 masked" "$masked" 'MIIabcdeflinetwo123'
assert_no_match "multi-line key line 2 masked" "$masked" 'MIItulinethree456'
assert_match    "multi-line key redacted"      "$masked" 'MASKED'

suite "build_limits (cgroup when enforceable, ulimit fallback otherwise)"
ULIMIT_NPROC=1024; ULIMIT_FSIZE=2147483648
RESOURCE_LIMITS=1; build_limits 2g 512; got="${_LIMITS[*]}"
assert_match    "force: --memory present"      "$got" '\-\-memory 2g'
assert_match    "force: --pids-limit present"  "$got" '\-\-pids-limit 512'
assert_match    "force: nproc floor always"    "$got" 'nproc=1024'   # M4: unconditional fork-bomb floor
assert_match    "force: fsize cap always"      "$got" 'fsize=2147483648'

RESOURCE_LIMITS=0; build_limits 2g 512; got="${_LIMITS[*]}"
assert_no_match "off: no cgroup --memory"      "$got" '\-\-memory'
assert_no_match "off: no cgroup --pids-limit"  "$got" 'pids-limit'
assert_match    "off: ulimit nproc fallback"   "$got" 'nproc=1024'

RESOURCE_LIMITS=auto; _CGROUP_DETECTED=1; CGROUP_MEM=0; CGROUP_PIDS=0; build_limits 2g 512; got="${_LIMITS[*]}"
assert_no_match "auto/no-cg: no --memory"      "$got" '\-\-memory'
assert_match    "auto/no-cg: nproc fallback"   "$got" 'nproc=1024'

RESOURCE_LIMITS=auto; _CGROUP_DETECTED=1; CGROUP_MEM=1; CGROUP_PIDS=1; build_limits 2g 512; got="${_LIMITS[*]}"
assert_match    "auto/cg: --memory present"    "$got" '\-\-memory 2g'
assert_match    "auto/cg: nproc floor present" "$got" 'nproc=1024'   # M4: always, even with cgroups

RESOURCE_LIMITS=auto; _CGROUP_DETECTED=1; CGROUP_MEM=1; CGROUP_PIDS=0; build_limits 2g 512; got="${_LIMITS[*]}"
assert_match    "mixed: --memory present"      "$got" '\-\-memory 2g'
assert_no_match "mixed: no --pids-limit"       "$got" 'pids-limit'
assert_match    "mixed: nproc fallback"        "$got" 'nproc=1024'

suite "valid_job (job-key validation — H2 yq-inject / H3 mkdir-DoS)"
assert_ok   "plain job accepted"          valid_job "deploy-site"
assert_ok   "dots/underscore accepted"    valid_job "build_v1.2"
assert_fail "slash rejected (mkdir DoS)"  valid_job "build/a"
assert_fail "yq-injection key rejected"   valid_job 'x" | load_str(env("X")) #'
assert_fail "quote rejected"              valid_job 'a"b'
assert_fail "space rejected"              valid_job 'a b'
assert_fail "empty rejected"              valid_job ''

suite "make_rundir (path-safe + bounded — H3)"
RUNS="$(mktemp -d)/runs"
d="$(make_rundir 20260628T000000Z deadbeef 'build/a')"   # slash would ENOENT-loop the old version
assert_ok       "rundir created despite slash in job" test -d "$d"
assert_no_match "job component sanitized (no slash in leaf)" "${d##*/}" '/'

rm -rf "$W"
summary
