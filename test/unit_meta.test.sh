#!/usr/bin/env bash
# Tier-1 unit tests for run-group.sh's meta writer + run-dir allocator (jesc, emit_meta,
# make_rundir). Sources run-group.sh — its source-guard means functions only, no main.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/harness.sh"
export CICD_BASE="$HERE/.."          # run-group sources $CICD_BASE/bin/lib.sh
# shellcheck source=/dev/null
. "$HERE/../bin/run-group.sh"        # _CICD_MAIN=0 -> defines functions, runs no main

suite jesc
assert_eq "escapes doublequote" "$(jesc 'a"b')"   'a\"b'
assert_eq "escapes backslash"   "$(jesc 'a\b')"   'a\\b'
assert_eq "passes plain"        "$(jesc 'plain')" 'plain'

suite emit_meta
META_repo="tovasol/agent-forge"; META_branch="main"; META_job="smoke"; META_event="push"
META_sha="2b670708"; META_pusher="git"; META_start="2026-06-23T05:09:41Z"; META_startns=1781701781000000000
TF="$(mktemp)"

emit_meta "$TF" running                                  # 2-arg start form
assert_eq   "running: one line"   "$(wc -l < "$TF" | tr -d ' ')" 1
assert_json "running: valid json" "$(cat "$TF")"
assert_match "running: status"    "$(cat "$TF")" '"status":"running"'
assert_match "running: end null"  "$(cat "$TF")" '"end":null'
assert_match "running: exit null" "$(cat "$TF")" '"exit":null'
# pin field VALUES to their keys (valid-JSON alone misses a repo<->branch swap or a zeroed ns)
assert_match "running: repo value"  "$(cat "$TF")" '"repo":"tovasol/agent-forge"'
assert_match "running: branch value" "$(cat "$TF")" '"branch":"main"'
assert_match "running: start_ns"    "$(cat "$TF")" '"start_ns":1781701781000000000'

emit_meta "$TF" exit:0 0 2026-06-23T05:10:00Z 1781701800000000000 19   # 6-arg final form
assert_json "final: valid json"   "$(cat "$TF")"
assert_match "final: status"      "$(cat "$TF")" '"status":"exit:0"'
assert_match "final: duration"    "$(cat "$TF")" '"duration_s":19'
assert_match "final: exit num"    "$(cat "$TF")" '"exit":0'
# the final form must actually write end / end_ns (not null) — catches them being dropped
assert_match "final: end iso"     "$(cat "$TF")" '"end":"2026-06-23T05:10:00Z"'
assert_match "final: end_ns"      "$(cat "$TF")" '"end_ns":1781701800000000000'

# adversarial: a doublequote in the branch must NOT break JSON
META_branch='feat/"injected'
emit_meta "$TF" running
assert_json  "quote in branch -> still valid json" "$(cat "$TF")"
assert_match "quote escaped"                       "$(cat "$TF")" 'feat/\\"injected'
rm -f "$TF"

suite make_rundir
RUNS="$(mktemp -d)/runs"             # global used by make_rundir
d1="$(make_rundir 20260623T100000Z deadbeef smoke)"
d2="$(make_rundir 20260623T100000Z deadbeef smoke)"   # SAME id -> collision -> suffix
assert_ok   "first dir created"   test -d "$d1"
assert_ok   "second dir created"  test -d "$d2"
assert_ne   "collision -> distinct dirs" "$d1" "$d2"
assert_match "leaf is slash-free run-id" "$(basename "$d1")" '^20260623T100000Z-deadbeef-smoke'
# D2: pin the collision-suffix SCHEME — the 2nd dir on a same-id collision must be the 1st's
# basename + '-1' (not merely distinct). Dropping the `-N` suffix logic breaks this.
assert_eq   "collision suffix is -1"     "$(basename "$d2")" "$(basename "$d1")-1"
# D1: an unsafe job component must be sanitized (`tr -c 'A-Za-z0-9._-' '_'`): 'a/b/c' -> 'a_b_c'
# so it can never become a nested path or escape RUNS. Deleting the tr leaves slashes in.
d3="$(make_rundir 20260623T100000Z deadbeef 'a/b/c')"
assert_match "unsafe job sanitized in leaf" "$(basename "$d3")" '^20260623T100000Z-deadbeef-a_b_c$'
assert_eq    "sanitized dir stays under RUNS" "$(dirname "$d3")" "$RUNS"
rm -rf "$(dirname "$RUNS")"

summary
