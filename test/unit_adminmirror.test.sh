#!/usr/bin/env bash
# Guards against gitolite-admin DRIFT: bin/post-receive and git/relnotes-hook are mirrored by
# hand into the gitolite-admin repo (local/hooks/repo-specific/cicd + cicd-relnotes). If you
# edit a mirrored source but forget to re-sync the admin copy, the deployed hook silently goes
# stale. This test fails when a mirrored file's hash no longer matches deploy/admin-mirror.sha256
# — i.e. you changed it. Fixing the failure forces the acknowledgement: re-sync gitolite-admin,
# then regenerate the manifest:
#     cd <repo>; for f in bin/post-receive git/relnotes-hook; do
#       printf '%s\t%s\n' "$f" "$(sha256sum "$f" | cut -d' ' -f1)"; done   # update the 2 hash lines
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/harness.sh"
ROOT="$HERE/.."
MANIFEST="$ROOT/deploy/admin-mirror.sha256"
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

suite "gitolite-admin mirror drift guard"
if [ ! -f "$MANIFEST" ]; then
  fail "manifest present" "missing $MANIFEST"
else
  ok "manifest present"
  while IFS=$'\t' read -r path want; do
    case "$path" in ''|'#'*) continue ;; esac
    got="$(sha "$ROOT/$path" 2>/dev/null || echo MISSING)"
    assert_eq "in sync: $path (re-sync gitolite-admin if this fails)" "$got" "$want"
  done < "$MANIFEST"
fi
summary
