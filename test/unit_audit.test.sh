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

# H5-audit: a leaked lock (writer killed mid-audit) must be RECLAIMED, not fail open / hang
suite "audit mkdir-mutex reclaims a leaked lock (H5-audit)"
SL="$T/stale.log"
if command -v flock >/dev/null 2>&1; then
  # flock path: mkdir lockdir is unused — just pin that the append still chains correctly
  AUDIT_LOG="$SL" cicd_audit ingest "repo=x"
  assert_ok "append verifies (flock path)" cicd_audit_verify "$SL"
else
  # The flock-less mkdir-mutex path is for BSD-stat hosts (macOS/busybox); `_audit_lock_stale`
  # uses BSD `stat -f %m`. If a GNU coreutils `stat` is shadowing the native BSD one on PATH
  # (common on dev Macs with homebrew), `stat -f %m` mis-parses and pollutes the mtime read, so
  # the TIME-based reclaim can't be exercised. Front /usr/bin (native BSD stat) for these cases —
  # a no-op on real Linux (which takes the flock branch and never reaches here).
  [ -x /usr/bin/stat ] && /usr/bin/stat -f %m / >/dev/null 2>&1 && PATH="/usr/bin:$PATH"
  LD="$SL.lock.d"; mkdir -p "$LD"; printf '999999\n' > "$LD/pid"   # leaked lock, owner pid dead
  AUDIT_LOCK_STALE_SECS=0 AUDIT_LOG="$SL" cicd_audit ingest "repo=x"
  assert_ok   "append after reclaim verifies" cicd_audit_verify "$SL"
  assert_eq   "exactly one entry written"     "$(grep -c '' "$SL")" "1"
  assert_fail "stale lockdir was reclaimed"   test -d "$LD"

  # (1) stale-by-AGE: a leaked lockdir with NO pid file inside (so the dead-owner kill -0
  # shortcut can't fire) and an OLD mtime must be reclaimed by the TIME-based path alone.
  # Inverting `_audit_lock_stale`'s (now-mtime) arithmetic makes a 2000-dated dir look fresh.
  SA="$T/age.log"; LDA="$SA.lock.d"; mkdir -p "$LDA"; touch -t 200001010000 "$LDA"
  AUDIT_LOCK_STALE_SECS=1 AUDIT_LOG="$SA" cicd_audit ingest "repo=x"
  assert_ok   "stale-by-age append verifies"  cicd_audit_verify "$SA"
  assert_eq   "stale-by-age: one entry"        "$(grep -c '' "$SA")" "1"
  assert_fail "stale-by-age lockdir reclaimed" test -d "$LDA"

  # (2) killed-writer / self-stamp: a writer holding the lock SELF-STAMPS its live pid so a later
  # contender can tell a dead holder (reclaim) from a live one (wait). We park a REAL holder inside
  # the critical section by making its log a FIFO — _cicd_audit_append's `>> "$logf"` blocks until
  # something reads the FIFO, so the holder sits in the lock with its pid stamped — then SIGKILL it.
  # The lockdir is now held by a DEAD pid with a FRESH mtime (NOT stale). A contender (stale window
  # huge) can ONLY reclaim via the dead-owner kill -0 shortcut, which reads that stamped pid. Gut
  # the self-stamp to `:` and there is no pid to read -> the contender can't see the holder is dead,
  # falls through to the (non-stale) time check, spins to the cap, and writes serialization=lost
  # instead of reclaiming + appending a clean single entry.
  if command -v mkfifo >/dev/null 2>&1; then
    SK="$T/killed.log"; mkfifo "$SK" 2>/dev/null || true
    # holder runs in its OWN process (bash -c) so the self-stamped `$$` IS this process's pid —
    # killing it leaves a lockdir owned by a genuinely-dead pid (a subshell would stamp the test
    # shell's still-alive pid). It sources lib.sh and blocks in the FIFO append, lock held + stamped.
    AUDIT_LOCK_STALE_SECS=99999 AUDIT_LOG="$SK" \
      bash -c '. "'"$HERE"'/../bin/lib.sh"; cicd_audit ingest repo=held' & holder=$!
    # spin until the holder has created the lockdir AND stamped its pid (proves it's inside)
    for _w in $(seq 1 200); do [ -s "$SK.lock.d/pid" ] && break; sleep 0.02; done
    kill -9 "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
    rm -f "$SK"; SKL="$T/killed2.log"     # fresh REAL file for the contender's clean append
    # move the dead-holder lockdir over to the contender's log path, fresh mtime, dead stamped pid
    mv "$SK.lock.d" "$SKL.lock.d" 2>/dev/null || true; touch "$SKL.lock.d" 2>/dev/null || true
    AUDIT_LOCK_MAX_SPINS=1 AUDIT_LOCK_STALE_SECS=99999 AUDIT_LOG="$SKL" cicd_audit job-end "repo=held" status=exit:0
    out_k="$(cat "$SKL" 2>/dev/null)"
    assert_no_match "killed-writer reclaimed, no give-up" "$out_k" 'serialization=lost'
    assert_ok       "killed-writer append verifies"       cicd_audit_verify "$SKL"
    assert_eq       "killed-writer: one clean entry"      "$(grep -c '' "$SKL")" "1"
  else skip "killed-writer self-stamp" "mkfifo unavailable"; fi

  # (3) give-up sentinel: a LIVE owner ($$ — this shell) holds a FRESH lock (not stale/reclaimable)
  # and the spin cap is 1, so serialization can't be had -> the appended line must carry the
  # `serialization=lost` sentinel (attributable fork). Mutating the sentinel string fails this.
  SG="$T/giveup.log"; LDG="$SG.lock.d"; mkdir -p "$LDG"; printf '%s\n' "$$" > "$LDG/pid"
  AUDIT_LOCK_MAX_SPINS=1 AUDIT_LOCK_STALE_SECS=99999 AUDIT_LOG="$SG" cicd_audit ingest "repo=x"
  assert_match "give-up appends serialization=lost" "$(cat "$SG")" 'serialization=lost'
  rm -rf "$LDG"
fi

summary
