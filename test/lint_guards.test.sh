#!/usr/bin/env bash
# STRUCTURAL guard (a source lint, not a behavior test). The /envstate confused-deputy class kept
# RECURRING: a new $ENVS host-I/O sink gets added with a bare `>`/`cat` and the safe_* wrapper is
# forgotten. It happened twice — the original sweep, then `last_attempt` (a legacy bare `>` the
# sweep skipped, re-opening a documented-closed class). Per-call-site discipline is fragile, so
# this lints the source: ANY future bare read/write of the job-controlled $ENVS RW bind mount
# RED-BUILDS here at commit time instead of shipping as a finding. Every host I/O on $ENVS MUST go
# through safe_write / safe_read / safe_persist (which symlink-reject). Those helpers operate on
# "$1", never the literal "$ENVS, so they never match these patterns.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/harness.sh"
RG="$HERE/../bin/run-group.sh"

suite "lint: no raw host I/O on the job-controlled \$ENVS mount (structural symlink guard)"

# WRITES — nothing may redirect onto "$ENVS; all writes go through `| safe_write` or safe_persist.
assert_eq "no bare '>'/'>>' redirect onto \$ENVS" \
  "$(grep -cE '>>?[[:space:]]*"\$ENVS' "$RG")" "0"

# READS — no bare `cat` of "$ENVS (must be safe_read), and no input redirect from "$ENVS.
assert_eq "no bare 'cat \$ENVS' read" \
  "$(grep -cE 'cat([[:space:]]|[[:space:]]--[[:space:]])[^|]*"\$ENVS' "$RG")" "0"
assert_eq "no '< \$ENVS' input redirect" \
  "$(grep -cE '<[[:space:]]*"\$ENVS' "$RG")" "0"

# Positive control: the safe_* helpers exist and ARE used (so the zero-counts mean "all wrapped",
# not "no $ENVS I/O at all" — a guard that passes by absence would be theater).
assert_match "safe_write helper defined"   "$(grep -E '^safe_write\(\)'   "$RG")" 'safe_write'
assert_match "safe_read helper defined"    "$(grep -E '^safe_read\(\)'    "$RG")" 'safe_read'
assert_match "safe_persist helper defined" "$(grep -E '^safe_persist\(\)' "$RG")" 'safe_persist'
assert_ok    "safe_write is actually used on \$ENVS" \
  sh -c "grep -qE 'safe_write[[:space:]]+\"\\\$ENVS' '$RG'"

suite "lint: ci-status duckdb-injection / terminal-ESC hardening (#3)"
CS="$HERE/../bin/ci-status"
assert_match    "cicd-out filter widened to '%/cicd-out/%'" "$(grep -E 'cicd-out' "$CS")" '%/cicd-out/%'
assert_no_match "old off-by-one filter is gone"             "$(grep -E 'NOT LIKE' "$CS")" 'cicd-out/meta.json'
assert_match    "runsql strips C0 control bytes"            "$(grep -E '^runsql\(\)' "$CS")" 'tr -d'

suite "lint: output.log host append is byte-capped (#4 disk-fill)"
assert_eq "every redact_log->output.log append is head -c capped" \
  "$(grep -cE 'redact_log "\$maskfile" >>"\$dir/output.log"' "$RG")" "0"
assert_ok "the capped form is present" \
  sh -c "grep -qE 'head -c \"\\\$\{LOG_MAX_BYTES' '$RG'"

summary
