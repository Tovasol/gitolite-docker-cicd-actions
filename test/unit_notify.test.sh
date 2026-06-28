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

suite "notify-email open-relay guard (H5)"
RT="$(mktemp -d)"; mkdir -p "$RT/bin"
cat > "$RT/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$RT/curl.args"; exit 0
EOF
chmod +x "$RT/bin/curl"
# project supplies recipient + spoofed From but NO smtp creds; host supplies the OPERATOR creds
printf 'NOTIFY_TO=attacker@evil.example\nMAILER_EMAIL=ceo@trusted-bank.example\n' > "$RT/proj.env"
printf 'SMTP_USER_NAME=operator-ci@company.com\nSMTP_USER_PWD=OperatorAppPassword\n'  > "$RT/host.env"
rl="$RT/output.log"; printf 'boom\n' > "$rl"
printf '{"repo":"x","branch":"main","sha":"d","job":"smoke","event":"push","pusher":"git"}\n' > "$RT/meta.json"
out="$(PATH="$RT/bin:$PATH" CICD_NOTIFY_ENV="$RT/proj.env" CICD_NOTIFY_HOST_ENV="$RT/host.env" \
  bash "$HERE/../bin/notify-email" smoke "error: boom" "$rl")"
assert_match "open-relay refused"          "$out" 'REFUSED'
assert_eq    "no curl call when refused"   "$([ -f "$RT/curl.args" ] && echo sent || echo none)" "none"
# control: a repo that brings its OWN smtp creds may mail its own recipient (curl runs)
printf 'SMTP_USER_NAME=proj-ci@evil.example\nSMTP_USER_PWD=projpass\n' >> "$RT/proj.env"
rm -f "$RT/curl.args"
out2="$(PATH="$RT/bin:$PATH" CICD_NOTIFY_ENV="$RT/proj.env" CICD_NOTIFY_HOST_ENV="$RT/host.env" \
  bash "$HERE/../bin/notify-email" smoke "error: boom" "$rl")"
assert_eq    "project-own-creds allowed"   "$([ -f "$RT/curl.args" ] && echo sent || echo none)" "sent"
rm -rf "$RT"

suite "notify-email guard covers endpoint + headers (H3 / M1)"
NG="$(mktemp -d)"; mkdir -p "$NG/bin"
cat > "$NG/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$NG/curl.args"; exit 0
EOF
chmod +x "$NG/bin/curl"
# operator creds live host-side; the To is host-tier too (no open-relay by itself)
printf 'SMTP_USER_NAME=operator-ci@company.com\nSMTP_USER_PWD=OperatorAppPassword\nNOTIFY_TO=ops@company.com\n' > "$NG/host.env"
rl2="$NG/output.log"; printf 'boom\n' > "$rl2"
printf '{"repo":"x","branch":"main","sha":"d","job":"smoke","event":"push","pusher":"git"}\n' > "$NG/meta.json"
runne() {  # <projenv-content with \n escapes> -> stdout of notify-email
  printf '%b' "$1" > "$NG/proj.env"; rm -f "$NG/curl.args"
  PATH="$NG/bin:$PATH" CICD_NOTIFY_ENV="$NG/proj.env" CICD_NOTIFY_HOST_ENV="$NG/host.env" \
    bash "$HERE/../bin/notify-email" smoke "error: boom" "$rl2"
}
# each of these, supplied by the PROJECT while creds are host-tier, must REFUSE (no curl)
assert_match "endpoint addr override refused"    "$(runne 'SMTP_HOST_ADDR=attacker.evil.example\n')" 'REFUSED'
assert_match "endpoint port override refused"    "$(runne 'SMTP_HOST_PORT=2525\n')"                   'REFUSED'
assert_match "From display-name override refused" "$(runne 'SMTP_FROM_NAME=Google Security <no-reply@accounts.google.com>\n')" 'REFUSED'
assert_match "Subject override refused"          "$(runne 'NOTIFY_SUBJECT=pwn\n')"                     'REFUSED'
assert_match "Body override refused"             "$(runne 'NOTIFY_BODY=pwn\n')"                        'REFUSED'
assert_eq    "no curl on any refusal"            "$([ -f "$NG/curl.args" ] && echo sent || echo none)" "none"
# password-tier split (the survivor): the username is PUBLIC, so a repo supplying the operator's
# username via the SMTP_USER alias (project tier, no password) must NOT dodge the guard — the
# decision keys on the PASSWORD tier (host), and a project-tier username is itself refused.
assert_match "project public-username (host pw) refused" "$(runne 'SMTP_USER=operator-ci@company.com\n')" 'REFUSED'
assert_match "project username + recipient refused"      "$(runne 'SMTP_USER=operator-ci@company.com\nNOTIFY_TO=attacker@evil.example\n')" 'REFUSED'
# a benign project that touches NOTHING host-sensitive must still send (no false refusal)
out_ok="$(runne 'NOTIFY_LOGLINES=10\n')"
assert_no_match "benign project not refused"     "$out_ok" 'REFUSED'
assert_eq       "benign project still sends"     "$([ -f "$NG/curl.args" ] && echo sent || echo none)" "sent"
rm -rf "$NG"

suite "notify-email SMTP DATA transparency (bare-LF / dot-stuffing)"
DG="$(mktemp -d)"; mkdir -p "$DG/bin"
cat > "$DG/bin/curl" <<EOF
#!/usr/bin/env bash
a=("\$@"); printf '%s\n' "\$@" > "$DG/curl.args"
for ((i=0;i<\${#a[@]};i++)); do [ "\${a[i]}" = --upload-file ] && cat "\${a[i+1]}" > "$DG/curl.data" 2>/dev/null; done
exit 0
EOF
chmod +x "$DG/bin/curl"
# all host-tier (guard passes -> curl runs); the LOG TAIL carries attacker-chosen lines
printf 'SMTP_USER_NAME=op@company.com\nSMTP_USER_PWD=pw\nNOTIFY_TO=ops@company.com\n' > "$DG/host.env"
printf '{"repo":"x","branch":"main","sha":"d","job":"smoke","event":"push","pusher":"git"}\n' > "$DG/meta.json"
rl4="$DG/output.log"; printf 'normal line\n.\n.MAIL FROM:<evil@x>\n' > "$rl4"
PATH="$DG/bin:$PATH" CICD_NOTIFY_ENV="" CICD_NOTIFY_HOST_ENV="$DG/host.env" \
  bash "$HERE/../bin/notify-email" smoke "error: boom" "$rl4" >/dev/null
data="$(cat "$DG/curl.data" 2>/dev/null)"
assert_match    "curl actually invoked"           "$([ -f "$DG/curl.data" ] && echo y || echo n)" "y"
assert_match    "lone '.' line is dot-stuffed"    "$data" '^\.\.'
assert_match    "leading-dot SMTP verb stuffed"   "$data" '\.\.MAIL FROM'
assert_no_match "no bare lone-dot (DATA end) line" "$data" '^\.$'
assert_match    "body lines are CRLF-terminated"  "$(printf '%s' "$data" | tr '\r' '@' )" 'normal line@'
rm -rf "$DG"

summary
