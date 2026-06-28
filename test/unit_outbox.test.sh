#!/usr/bin/env bash
# cicd_flush_outbox must redact secrets in SCRIPT-AUTHORED notify messages: those arrive via
# the outbox and bypass the container-stream redactor, so without this they'd leak into
# output.log and the notify email. (Closes the residual from the secret-redaction work.)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/harness.sh"
# shellcheck source=/dev/null
. "$HERE/../bin/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

suite "cicd_flush_outbox secret redaction"
printf 'success\tdeployed token=supersecretvalue123 ok\n' > "$T/box"   # <level>\t<msg>
printf 's/supersecretvalue123/[MASKED]/g\n' > "$T/mask"
REC="$T/notify.rec"; : > "$REC"
cat > "$T/notify" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$2" >> "$REC"     # cicd_deliver passes arg2 = "<level>: <msg>"
EOF
chmod +x "$T/notify"

# with a mask file -> secret masked in the log AND in the delivered message
DIR="$T/run"; mkdir -p "$DIR"; : > "$DIR/output.log"
NOTIFY_CMD="$T/notify" cicd_flush_outbox "$T/box" 0 "$DIR" "tovasol/app/smoke" "" "$T/mask"
assert_no_match "output.log masks the secret" "$(cat "$DIR/output.log")" 'supersecretvalue123'
assert_match    "output.log shows [MASKED]"   "$(cat "$DIR/output.log")" 'MASKED'
assert_no_match "delivered message masked"    "$(cat "$REC")"            'supersecretvalue123'
# POSITIVELY pin the delivery: the masked BODY (not just absence-of-secret) must be delivered,
# and REC must be non-empty — "no secret leaked" is otherwise satisfied by delivering nothing.
assert_ne       "a message was actually delivered" "$(cat "$REC")" ""
assert_match    "delivered body is the masked message" "$(cat "$REC")" 'success: deployed token=\[MASKED\] ok'

# failure backstop: rc!=0 with an EMPTY box (script emitted no notify) must alert
DIRf="$T/runf"; mkdir -p "$DIRf"; : > "$DIRf/output.log"; : > "$T/empty"; : > "$REC"
NOTIFY_CMD="$T/notify" cicd_flush_outbox "$T/empty" 1 "$DIRf" "tovasol/app/smoke" ""
assert_match    "backstop alerts on silent failure" "$(cat "$REC")" 'job failed .rc=1. with no script notification'

# but NOT when the script already emitted a terminal notify (had_terminal=1 suppresses it)
DIRt="$T/runt"; mkdir -p "$DIRt"; : > "$DIRt/output.log"; : > "$REC"
NOTIFY_CMD="$T/notify" cicd_flush_outbox "$T/box" 1 "$DIRt" "tovasol/app/smoke" ""
assert_no_match "no double-alert when script notified" "$(cat "$REC")" 'with no script notification'

# rc=0 must NOT trigger the backstop even with an empty box
DIRz="$T/runz"; mkdir -p "$DIRz"; : > "$DIRz/output.log"; : > "$REC"
NOTIFY_CMD="$T/notify" cicd_flush_outbox "$T/empty" 0 "$DIRz" "tovasol/app/smoke" ""
assert_no_match "no backstop on success"          "$(cat "$REC")" 'with no script notification'

# no mask file -> message passes through unchanged (back-compat; redaction is opt-in by maskfile)
DIR2="$T/run2"; mkdir -p "$DIR2"; : > "$DIR2/output.log"
NOTIFY_CMD="" cicd_flush_outbox "$T/box" 0 "$DIR2" "x" ""
assert_match "no maskfile -> raw msg in log"  "$(cat "$DIR2/output.log")" 'supersecretvalue123'

suite "cicd_flush_outbox rejects a symlink outbox (H2 exfil guard)"
# a job plants notify -> the host age MASTER key; the host-side read must NOT follow it
DIRs="$T/runs"; mkdir -p "$DIRs"; : > "$DIRs/output.log"
SECRET="$T/host-age-key"; printf 'AGE-SECRET-KEY-A1B2C3\n' > "$SECRET"
ln -sf "$SECRET" "$T/sbox"; : > "$REC"
NOTIFY_CMD="$T/notify" cicd_flush_outbox "$T/sbox" 0 "$DIRs" "tovasol/app/smoke" ""
assert_no_match "master key NOT read into output.log" "$(cat "$DIRs/output.log")" 'AGE-SECRET-KEY-A1B2C3'
assert_match    "refusal noted in the log"            "$(cat "$DIRs/output.log")" 'symlink'
assert_eq       "nothing delivered from symlink box"  "$(cat "$REC")" ""
assert_fail     "symlink box removed"                 test -e "$T/sbox"

summary
