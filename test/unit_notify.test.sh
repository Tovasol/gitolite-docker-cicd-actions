#!/usr/bin/env bash
# Tier-1 unit test for notify-email: a NOTIFY_TO with several comma-separated recipients
# must yield ONE --mail-rcpt per address on the curl envelope (curl does not split a
# comma list — a single --mail-rcpt with commas is a bogus recipient). The To: header
# keeps the full list. Mocks curl on PATH to capture the envelope args.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/harness.sh"

suite "notify-email multi-recipient"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# mock curl: record args one-per-line, succeed (no network).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP/curl.args"
exit 0
EOF
chmod +x "$TMP/bin/curl"

# project notify env (stands in for the repo's decrypted sops secrets), two recipients
# with a space after the comma — exercises trimming.
cat > "$TMP/notify.env" <<'EOF'
SMTP_USER_NAME=ci@example.com
SMTP_USER_PWD=app-password
MAILER_EMAIL=ci@example.com
NOTIFY_TO=notify@tovasol.com , notify@example.com
EOF

# a run dir: log + meta.json beside it (notify reads meta for interpolation)
runlog="$TMP/output.log"; printf 'build failed\nboom\n' > "$runlog"
printf '{"repo":"tovasol/x","branch":"main","sha":"deadbeef","job":"smoke","event":"push","pusher":"git"}\n' \
  > "$TMP/meta.json"

audit="$(PATH="$TMP/bin:$PATH" CICD_NOTIFY_ENV="$TMP/notify.env" \
  bash "$HERE/../bin/notify-email" smoke "error: boom" "$runlog")"

args="$(cat "$TMP/curl.args" 2>/dev/null || true)"
n="$(grep -c -- '--mail-rcpt' "$TMP/curl.args" 2>/dev/null || echo 0)"
assert_eq      "one --mail-rcpt per recipient" "$n" "2"
assert_match   "first recipient on envelope"   "$args" 'tovasol\+cicdnotification@gmail\.com'
assert_match   "second recipient on envelope"  "$args" 'notify2\+cicdnotification@gmail\.com'
assert_no_match "addresses not comma-joined"   "$args" 'gmail\.com,'   # no single bogus rcpt
assert_no_match "second addr has no leading ws" "$args" ' notify2'    # trimmed (leading)
assert_no_match "first addr has no trailing ws" "$args" 'gmail\.com $'  # trimmed (trailing)

# audit line (captured by cicd_deliver into the run log) must record BOTH recipients
assert_match "audit line reports sent"        "$audit" 'notify-email: sent'
assert_match "audit names first recipient"    "$audit" 'tovasol\+cicdnotification@gmail\.com'
assert_match "audit names second recipient"   "$audit" 'notify2\+cicdnotification@gmail\.com'
assert_match "audit joins recipients with comma+space" "$audit" 'gmail\.com, notify2'

summary
