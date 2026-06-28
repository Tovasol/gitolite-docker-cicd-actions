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
# L2/L3: the rule count is bounded so a pathological secrets file can't fork unboundedly
ENVF3="$W/env3"; MASK3="$W/mask3"; : > "$ENVF3"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do printf 'SECRET_%s=valuevaluevalue%s\n' "$i" "$i" >> "$ENVF3"; done
MASK_MAX_RULES=5 build_mask_script "$ENVF3" "$MASK3"
assert_eq "mask rules capped at MASK_MAX_RULES" "$(grep -c '^s/' "$MASK3")" "5"

# H6 escape-bypass: a \c escape inside a multi-line value must NOT drop the segments AFTER it.
# printf '%b' stops at \c -> no mask rule for TAILSEGMENT789 (leak); the awk \n-split emits a rule
# for every \n-delimited segment, so a clean segment after the \c-bearing one is still masked.
ENVF4="$W/env4"; MASK4="$W/mask4"
printf 'K=FIRSTSEGMENT123\\nMIDDLE\\cWITHESCAPE\\nTAILSEGMENT789\n' > "$ENVF4"
build_mask_script "$ENVF4" "$MASK4"
assert_match    "rule emitted for post-\\c segment" "$(cat "$MASK4")" 'TAILSEGMENT789'
t4="$(printf '%s\n' 'TAILSEGMENT789' | redact_log "$MASK4")"
assert_no_match "segment after \\c is masked"       "$t4" 'TAILSEGMENT789'

# DoS: TOTAL rules (not entry count) are capped — a few keys with many \n-segments can't blow past
ENVF5="$W/env5"; MASK5="$W/mask5"
seg=""; for i in $(seq 1 50); do seg="${seg}SEGMENTVALUE$i\\n"; done
printf 'BIGKEY1=%s\nBIGKEY2=%s\nBIGKEY3=%s\n' "$seg" "$seg" "$seg" > "$ENVF5"
MASK_MAX_RULES=20 build_mask_script "$ENVF5" "$MASK5"
n5="$(grep -c '^s/' "$MASK5")"
assert_ok "total rules bounded near cap (got $n5)" test "$n5" -le 60   # emax + one key's ≤200 segs

# #2: sops escapes a real TAB/CR as literal \t/\r in the env-file; a consumer that DECODES them
# (printf %b, tr -d '\r') prints the real control byte, which the literal-form rule misses. The
# decoded-form rule must still mask it.
ENVF6="$W/env6"; MASK6="$W/mask6"
printf 'TABKEY=PREFIXAAAA\\tSUFFIXBBBB_LIVE\n' > "$ENVF6"
build_mask_script "$ENVF6" "$MASK6"
dec="$(printf '%b' 'PREFIXAAAA\tSUFFIXBBBB_LIVE' | redact_log "$MASK6")"
assert_no_match "decoded-tab secret masked (#2)" "$dec" 'SUFFIXBBBB_LIVE'
ENVF7="$W/env7"; MASK7="$W/mask7"
printf 'PEMKEY=LINEAAAA111\\r\\nLINEBBBB222\\r\\n\n' > "$ENVF7"
build_mask_script "$ENVF7" "$MASK7"
crlf="$(printf '%b' 'LINEAAAA111\r\nLINEBBBB222' | tr -d '\r' | redact_log "$MASK7")"
assert_no_match "decoded CRLF line 1 masked (#2)" "$crlf" 'LINEAAAA111'
assert_no_match "decoded CRLF line 2 masked (#2)" "$crlf" 'LINEBBBB222'

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

suite "safe_persist (symlink-guarded host write — H1)"
SP="$(mktemp -d)"
printf 'ATTACKER-PAYLOAD\n' > "$SP/src.tar"
printf 'VICTIM-ORIGINAL\n'  > "$SP/victim"
ln -sf "$SP/victim" "$SP/dst"                 # container planted dst -> a host file (e.g. authorized_keys)
safe_persist "$SP/src.tar" "$SP/dst"
assert_eq    "victim NOT overwritten through the symlink" "$(cat "$SP/victim")" "VICTIM-ORIGINAL"
assert_fail  "dst is no longer a symlink"                 test -L "$SP/dst"
assert_eq    "dst holds the real source bytes"            "$(cat "$SP/dst")" "ATTACKER-PAYLOAD"
# a planted symlink AT THE TEMP NAME can't be followed either
ln -sf "$SP/victim" "$SP/dst2.tmp.$$"; printf 'X\n' > "$SP/src2"
safe_persist "$SP/src2" "$SP/dst2"
assert_eq    "temp-name symlink didn't hit victim"        "$(cat "$SP/victim")" "VICTIM-ORIGINAL"
rm -rf "$SP"

suite "per-repo cache path flattens '/' (no nesting — H4)"
# assert the PRODUCTION cache_subdir (sourced from run-group.sh), not a local re-impl — so a
# mutation that no-ops the '/' -> '%' flattening is caught here, not hidden behind a copy.
assert_eq "team -> team (prod fn)"          "$(cache_subdir team)"     "team"
assert_eq "team/app -> team%app (prod fn)"  "$(cache_subdir team/app)" "team%app"
# the parent-named repo's dir must NOT be a path-prefix DIR of the child's (the H4 bug)
case "$(cache_subdir team/app)" in "$(cache_subdir team)"/*) nested=yes ;; *) nested=no ;; esac
assert_eq "team%app is not nested under team (prod fn)" "$nested" "no"

suite "safe_write / safe_read — /envstate symlink guards (F1/F2)"
EV="$(mktemp -d)"
# F2: a job plants $ENVS/branch -> a host victim; safe_write must NOT write THROUGH the symlink
printf 'VICTIM-ORIGINAL\n' > "$EV/victim"
ln -sf "$EV/victim" "$EV/branch"
printf 'main' | safe_write "$EV/branch"
assert_eq    "safe_write didn't write through symlink" "$(cat "$EV/victim")" "VICTIM-ORIGINAL"
assert_fail  "dst is no longer a symlink"              test -L "$EV/branch"
assert_eq    "dst holds the intended content"          "$(cat "$EV/branch")" "main"
# F1: a job plants $ENVS/teardown.cmd -> the host master key; safe_read must REFUSE to follow it
printf 'AGE-SECRET-KEY-MASTER\n' > "$EV/agekey"
ln -sf "$EV/agekey" "$EV/teardown.cmd"
got="$(safe_read "$EV/teardown.cmd" 2>/dev/null)"; rc=$?
assert_ne    "safe_read refused the symlink (nonzero)" "$rc" 0
assert_no_match "master key NOT returned"              "$got" 'AGE-SECRET-KEY-MASTER'
# a real regular file reads back fine
printf 'echo bye\n' > "$EV/real.cmd"
assert_eq    "safe_read reads a regular file"          "$(safe_read "$EV/real.cmd")" "echo bye"
rm -rf "$EV"

suite "valid_branch — stored branch re-validation (F3)"
# valid_branch wraps `git check-ref-format`; reap-envs/ci-teardown/run-group run on the gitolite
# HOST (git always present). The CI test CONTAINER (node:20-alpine) may lack git — skip there (in
# prod a missing git makes valid_branch fail-SAFE: the branch is rejected, teardown skipped).
if command -v git >/dev/null 2>&1; then
  assert_ok   "normal branch accepted"        valid_branch "main"
  assert_ok   "slashy feature branch accepted" valid_branch "feature/x-1"
  assert_fail "traversal branch rejected"     valid_branch "../../../../ESCAPED/run"
  assert_fail "dotdot component rejected"     valid_branch "a/../../etc"
  assert_fail "empty rejected"                valid_branch ""
  assert_fail "space rejected"                valid_branch "a b"
else
  skip "valid_branch F3 checks" "git not in this environment (host-only code path)"
fi

suite "valid_env_key — custom env-key validation (F4)"
assert_ok   "plain key accepted"            valid_env_key "API_KEY"
assert_fail "glob key '*' rejected"         valid_env_key "*"
assert_fail "space in key rejected"         valid_env_key "MY VAR"
assert_fail "empty key rejected"            valid_env_key ""
assert_fail "leading-digit rejected"        valid_env_key "1ABC"
assert_fail "dash rejected"                 valid_env_key "A-B"

rm -rf "$W"
summary
