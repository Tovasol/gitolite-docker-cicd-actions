#!/usr/bin/env bash
# Unit tests for the hash-chained audit log (cicd_audit / cicd_audit_verify in lib.sh):
# entries chain from GENESIS, the chain verifies, any tamper is detected, and a field value
# that itself contains "prev="/"hash=" can't fool the parser.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/harness.sh"
# shellcheck source=/dev/null
. "$HERE/../bin/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

suite "audit log (hash chain)"
AUDIT_ENABLED=1; AUDIT_LOG="$T/audit.log"
cicd_audit ingest    repo=tovasol/app branch=main event=push pusher=alice
cicd_audit job-start repo=tovasol/app job=smoke
cicd_audit job-end   repo=tovasol/app job=smoke status=exit:0

assert_eq    "3 entries written"          "$(grep -c '' "$AUDIT_LOG")" "3"
assert_match "first chains from GENESIS"  "$(head -1 "$AUDIT_LOG")"    'prev=GENESIS'
assert_ok    "intact chain verifies"      cicd_audit_verify "$AUDIT_LOG"

# tamper a middle line -> chain breaks
cp "$AUDIT_LOG" "$T/tampered.log"
sed 's/job=smoke/job=HACKED/' "$T/tampered.log" > "$T/tampered2.log"
assert_fail  "tampered line detected"     cicd_audit_verify "$T/tampered2.log"

# delete a line -> chain breaks
sed '2d' "$AUDIT_LOG" > "$T/deleted.log"
assert_fail  "deleted line detected"      cicd_audit_verify "$T/deleted.log"

# a field value containing prev=/hash= must not fool the LAST-occurrence parser
A2="$T/a2.log"
AUDIT_LOG="$A2" cicd_audit weird "note=prev=spoof and hash=deadbeef inside a field"
AUDIT_LOG="$A2" cicd_audit next  ok=1
assert_ok    "field with prev=/hash= still verifies" cicd_audit_verify "$A2"

# disabled -> nothing written
A3="$T/a3.log"
AUDIT_ENABLED=0 AUDIT_LOG="$A3" cicd_audit ingest repo=x
assert_eq    "disabled writes no log"     "$([ -f "$A3" ] && echo yes || echo no)" "no"

summary
