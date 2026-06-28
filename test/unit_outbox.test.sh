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

# no mask file -> message passes through unchanged (back-compat; redaction is opt-in by maskfile)
DIR2="$T/run2"; mkdir -p "$DIR2"; : > "$DIR2/output.log"
NOTIFY_CMD="" cicd_flush_outbox "$T/box" 0 "$DIR2" "x" ""
assert_match "no maskfile -> raw msg in log"  "$(cat "$DIR2/output.log")" 'supersecretvalue123'

summary
