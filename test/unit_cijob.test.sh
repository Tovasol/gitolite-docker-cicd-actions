#!/usr/bin/env bash
# Unit tests for the `ci-job` gitolite command. The real gitolite/git/sudo are mocked
# with PATH stubs so the COMMAND LOGIC is tested hermetically: access gating (run needs
# W, log needs R), the run delivery wiring (event/sha/onlyjob into cicd-ingest), --ref,
# and the access-scoped status (only readable repos reach ci-status --repos).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/harness.sh"
CIJOB="$HERE/../git/ci-job"

# --- build a mock environment (gitolite + git + sudo + proxied runner bins) -----------
M="$(mktemp -d)"; STUB="$M/bin"; mkdir -p "$STUB"
REC="$M/calls.log"; : > "$REC"
# access fixture: lines "<repo> <perm> <user>"
cat > "$M/access" <<'EOF'
tovasol/app W alice
tovasol/app R alice
tovasol/lib R alice
EOF
printf '%s\n' tovasol/app tovasol/lib tovasol/secret > "$M/repos"   # all physical repos

cat > "$STUB/gitolite" <<EOF
#!/usr/bin/env bash
case "\$1" in
  access)  # access -q <repo> <user> <perm>
    grep -qx "\$3 \$5 \$4" "$M/access" && exit 0 || exit 1 ;;
  query-rc) [ "\$2" = GL_REPO_BASE ] && echo "$M/repositories" ;;
  list-phy-repos) cat "$M/repos" ;;
  info)  # emulate \`gitolite info\`: header + "<flags>\t<repo>" per repo GL_USER can access
    echo "hello \${GL_USER:-?}, this is git@test"; echo
    while read -r r; do
      perms=""
      grep -qx "\$r R \${GL_USER:-}" "$M/access" && perms="R"
      grep -qx "\$r W \${GL_USER:-}" "$M/access" && perms="\${perms:+\$perms }W"
      [ -n "\$perms" ] && printf ' %s\t%s\n' "\$perms" "\$r"
    done < "$M/repos" ;;
esac
EOF
cat > "$STUB/git" <<EOF
#!/usr/bin/env bash
# only rev-parse + archive are used
for a in "\$@"; do case "\$a" in
  rev-parse) echo "deadbeefcafe1234567890aaaaaaaaaaaaaaaaaa"; exit 0 ;;
  archive)   echo "FAKE-TAR-BYTES"; exit 0 ;;
esac; done
exit 0
EOF
cat > "$STUB/sudo" <<'EOF'
#!/usr/bin/env bash
# sudo -n -u <user> <cmd> <args...>  -> just exec <cmd> <args...>
while [ $# -gt 0 ]; do case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac; done
exec "$@"
EOF
# proxied runner bins (recorded): cicd-ingest, ci-status, ci-log
RB="$M/runner-bin"; mkdir -p "$RB"
for b in cicd-ingest ci-status ci-log; do
  cat > "$RB/$b" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$b" "\$*" >> "$REC"
cat >/dev/null 2>&1 || true
EOF
  chmod +x "$RB/$b"
done
# stateful ci-runs stub for --watch: poll 1 = not started, 2-3 = running, 4+ = exit:0
SHA=deadbeefcafe1234567890aaaaaaaaaaaaaaaaaa
cat > "$RB/ci-runs" <<EOF
#!/usr/bin/env bash
c="$M/poll.n"; n=\$(( \$(cat "\$c" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "\$c"
if   [ "\$n" -ge 4 ]; then echo '{"schema":1,"repo":"tovasol/app","job":"deploy","sha":"$SHA","status":"exit:0"}'
elif [ "\$n" -ge 2 ]; then echo '{"schema":1,"repo":"tovasol/app","job":"deploy","sha":"$SHA","status":"running"}'
fi
EOF
chmod +x "$RB/ci-runs"
chmod +x "$STUB"/*
# fake bare repo dirs so [ -d gitdir ] passes
mkdir -p "$M/repositories/tovasol/app.git" "$M/repositories/tovasol/lib.git" "$M/repositories/tovasol/secret.git"

run_cijob() {  # <gl_user> <args...>
  GL_USER="$1" PATH="$STUB:$PATH" HOME="$M" CICD_RUNNER_BIN="$RB" \
    bash "$CIJOB" "${@:2}" 2>&1
}

suite "ci-job run (access + delivery)"
: > "$REC"; out="$(run_cijob alice run tovasol/app main --job deploy)"; rc=$?
assert_eq    "run with W access succeeds"        "$rc" 0
assert_match "ingest got event=run + sha + job"  "$(cat "$REC")" 'cicd-ingest tovasol/app main run deadbeefcafe1234567890aaaaaaaaaaaaaaaaaa 0+ alice deploy'
: > "$REC"; out="$(run_cijob alice run tovasol/lib main)"; rc=$?
assert_ne    "run WITHOUT write access fails"    "$rc" 0
assert_match "denial mentions WRITE"             "$out" 'no WRITE access'
assert_eq    "no ingest on denial"               "$(grep -c cicd-ingest "$REC")" 0
: > "$REC"; run_cijob alice run tovasol/secret main >/dev/null 2>&1
assert_eq    "no access at all -> no ingest"     "$(grep -c cicd-ingest "$REC")" 0

suite "ci-job status (access-scoped)"
: > "$REC"; run_cijob alice status >/dev/null 2>&1
got="$(grep '^ci-status' "$REC")"
assert_match "status scopes to readable repos" "$got" 'ci-status --repos .*tovasol/app'
assert_match "status includes lib (readable)"  "$got" 'tovasol/lib'
assert_no_match "status EXCLUDES secret (no R)" "$got" 'tovasol/secret'

suite "ci-job log (access gated)"
: > "$REC"; run_cijob alice log tovasol/app deploy >/dev/null 2>&1
assert_match "log proxies ci-log for readable repo" "$(cat "$REC")" 'ci-log tovasol/app deploy'
: > "$REC"; out="$(run_cijob alice log tovasol/secret deploy)"; rc=$?
assert_ne    "log on unreadable repo fails"     "$rc" 0
assert_eq    "no ci-log call on denial"         "$(grep -c '^ci-log' "$REC")" 0

suite "ci-job run --watch (polls status, no queue bypass)"
rm -f "$M/poll.n"
out="$(GL_USER=alice PATH="$STUB:$PATH" HOME="$M" CICD_RUNNER_BIN="$RB" \
       CIJOB_POLL=0 CIJOB_POLL_MAX=12 bash "$CIJOB" run tovasol/app main --job deploy --watch 2>&1)"
assert_match "watch shows 'running' transition"     "$out" 'running'
assert_match "watch shows terminal 'exit:0'"        "$out" 'exit:0'
assert_no_match "watch does NOT tail a missing log" "$out" 'No such file'

rm -rf "$M"
summary
