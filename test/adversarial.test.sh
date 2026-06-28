#!/usr/bin/env bash
# Tier-2 adversarial / seam-fuzz tests: hostile inputs at the boundaries.
#   1. malicious tar (path traversal + symlink escape) — extraction must stay contained.
#   2. corrupt/truncated meta.json — ci-runs must drop it, queries must not break.
#   3. malformed .gitolite/ci.yml — yq helpers must return empty, not crash.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/harness.sh"
export CICD_BASE="$HERE/.."
# shellcheck source=/dev/null
. "$HERE/../bin/lib.sh"

suite "tar extraction containment"
FIX="$HERE/adversarial/evil-traversal.tar"
if [ -f "$FIX" ]; then
  base="$(mktemp -d)"; work="$base/x/y"; mkdir -p "$work"
  # exactly what run-group does: tar -x into the work dir
  tar -x -C "$work" -f "$FIX" 2>/dev/null || true
  assert_ok "../ traversal blocked"        test ! -e "$base/x/escape-parent.txt"
  assert_ok "../../ traversal blocked"     test ! -e "$base/escape-deep.txt"
  assert_ok "no write through symlink-out" test ! -e "/tmp/symlink-escape-target"
  rm -rf "$base"; rm -f "/tmp/symlink-escape-target"
else skip "tar fixture" "evil-traversal.tar missing"; fi

suite "corrupt meta resilience (ci-runs filter)"
# build a fake base so ci-runs resolves RUNNER_BASE, drop good + garbage + truncated meta
TB="$(mktemp -d)"; mkdir -p "$TB/bin" "$TB/etc"
cp "$HERE/../bin/lib.sh" "$TB/bin/"
printf 'RUNNER_BASE=%s\n' "$TB" > "$TB/etc/runner.conf"
RD="$TB/runs/tovasol/agent-forge"
mkdir -p "$RD/good" "$RD/garbage" "$RD/trunc"
printf '{"schema":1,"repo":"tovasol/agent-forge","job":"smoke","status":"exit:0","exit":0}\n' > "$RD/good/meta.json"
printf 'NOT JSON AT ALL {{{\n'                                                                 > "$RD/garbage/meta.json"
printf '{"schema":1,"repo":"tovasol/agent-forge","job":"trunc'                                  > "$RD/trunc/meta.json"  # truncated, no newline/close
out="$(CICD_BASE="$TB" bash "$HERE/../bin/ci-runs" 2>/dev/null)"
# count ALL non-empty lines (not just ^{.*}$ — a weakened/removed JSON guard leaks extra
# lines that don't end in }, which the old anchored count silently ignored).
assert_eq    "ci-runs emits exactly 1 line total"  "$(printf '%s\n' "$out" | grep -c .)" 1
assert_match "valid line is the good one"          "$out" '"job":"smoke"'
# the WHOLE POINT of ci-runs is enriching each meta with its run dir — assert the "dir" field
# actually carries the run's directory (leaf 'good'), not just that the line is valid JSON.
assert_match "line carries its run dir"            "$out" '"dir":"[^"]*/good"'
# the emitted line must be VALID JSON — an off-by-one substr ($0,2 -> $0,1) makes it malformed.
assert_json  "emitted line is valid JSON"          "$out"
# neither garbage ('NOT JSON...' becomes 'OT JSON...' after substr) nor the truncated meta may
# leak (the old 'NOT JSON' pattern never matched the post-substr form — it was vacuous).
assert_no_match "garbage/truncated payload dropped" "$out" 'JSON|trunc'
# DuckDB (ci-status's engine) reads the same run dirs directly; ignore_errors + the schema
# filter must drop the garbage/truncated meta and keep exactly the 1 valid row.
if command -v duckdb >/dev/null 2>&1; then
  n="$(duckdb -noheader -list -c "SELECT count(*) FROM read_json('$RD/**/meta.json', format='newline_delimited', ignore_errors=true, union_by_name=true) WHERE schema IS NOT NULL" 2>/dev/null)"
  assert_eq "duckdb glob skips corrupt (1 valid row)" "${n:-x}" 1
else skip "duckdb glob" "duckdb not installed"; fi
rm -rf "$TB"

suite "malformed ci.yml tolerance"
BY="$(mktemp)"; printf 'jobs:\n  deploy:\n    on: { push:\n  this is : not valid : yaml ][\n' > "$BY"
assert_ok    "yq_keys does not crash on bad yaml" bash -c "yq_keys '$BY' '.jobs' >/dev/null 2>&1; true"
assert_eq    "yq_keys returns empty on bad yaml"  "$(yq_keys "$BY" '.jobs' 2>/dev/null)" ""
rm -f "$BY"
# POSITIVE case: feeding only malformed yaml lets a gutted yq_keys(){ :; } pass vacuously.
# Pin that on VALID yaml yq_keys actually returns the keys (build, deploy). Needs yq v4.
if command -v yq >/dev/null 2>&1; then
  GY="$(mktemp)"; printf 'jobs:\n  build: {}\n  deploy: {}\n' > "$GY"
  assert_eq "yq_keys lists keys on valid yaml" "$(yq_keys "$GY" '.jobs' | sort | tr '\n' ',')" "build,deploy,"
  rm -f "$GY"
else skip "yq_keys valid yaml" "yq not installed"; fi

summary
