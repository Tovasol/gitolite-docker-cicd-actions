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

# tamper ONLY the prev= field of a middle line (hash= intact) -> the chain-LINK guard must
# catch it; without the rec_prev!=prev check, the hash still recomputes clean (a survivor).
sed '2 s/prev=[0-9a-f]*/prev=GENESIS/' "$AUDIT_LOG" > "$T/prevtamper.log"
assert_fail  "prev-field tamper detected" cicd_audit_verify "$T/prevtamper.log"

# a field containing REAL tabs must be neutralized (collapsed to spaces) so it can't forge
# extra columns -> the line must stay exactly 5 tab-separated fields (ts ev fields prev hash).
AUDIT_LOG="$T/tab.log" cicd_audit ev "note=x$(printf '\t')y$(printf '\t')z"
assert_eq    "tabs in a field neutralized (5 cols)" "$(awk -F'\t' 'NR==1{print NF; exit}' "$T/tab.log")" "5"

# a trailing blank line is tolerated (skipped), not treated as a broken entry
cp "$AUDIT_LOG" "$T/blank.log"; printf '\n' >> "$T/blank.log"
assert_ok    "blank line tolerated"       cicd_audit_verify "$T/blank.log"

# a missing log verifies OK (nothing to break)
assert_ok    "missing log verifies OK"    cicd_audit_verify "$T/does-not-exist.log"

# disabled -> nothing written
A3="$T/a3.log"
AUDIT_ENABLED=0 AUDIT_LOG="$A3" cicd_audit ingest repo=x
assert_eq    "disabled writes no log"     "$([ -f "$A3" ] && echo yes || echo no)" "no"

# L4: control bytes (CR/ESC/...) in a field must be stripped, not just NL/TAB
AUDIT_LOG="$T/l4.log" cicd_audit ev "job=build$(printf '\r')FAKEpusher$(printf '\033')[31m"
assert_no_match "no CR in audit line"     "$(cat -v "$T/l4.log" 2>/dev/null)" '\^M'
assert_no_match "no ESC in audit line"    "$(cat -v "$T/l4.log" 2>/dev/null)" '\^\['

# L1: concurrent writers must NOT fork the chain (the bare fd-redirect didn't serialize)
CL="$T/conc.log"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do AUDIT_LOG="$CL" cicd_audit ev "n=$i" & done; wait
assert_ok    "concurrent appends verify"  cicd_audit_verify "$CL"
assert_eq    "all 12 concurrent entries"  "$(grep -c '' "$CL")" "12"

summary
