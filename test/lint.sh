#!/usr/bin/env bash
# Tier-0 static analysis: `bash -n` (always) + shellcheck (if present; fetched in CI).
# Catches the exact class that's bitten us — quoting / unset-var / word-split bugs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$HERE/.."
# shellcheck source=/dev/null
. "$HERE/harness.sh"

# scripts to lint: bin/* + lib/* + installers + the repo-side ci/*.sh + the tests.
mapfile -t FILES < <(
  ls "$ROOT"/bin/* "$ROOT"/lib/* "$ROOT"/install.sh "$ROOT"/update-runner.sh \
     "$ROOT"/../ci/*.sh "$HERE"/*.sh 2>/dev/null | grep -vE '\.sample$'
)

suite "bash -n (parse)"
for f in "${FILES[@]}"; do [ -f "$f" ] && assert_ok "bash -n ${f##*/}" bash -n "$f"; done

suite "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # -S error: gate only on genuine errors (not style/info), so legacy quoting choices
  # don't block the build; tighten to -S warning later. -x: follow sourced files.
  for f in "${FILES[@]}"; do [ -f "$f" ] && assert_ok "shellcheck ${f##*/}" shellcheck -S error -x "$f"; done
else
  skip "shellcheck" "not installed (ci/test.sh installs it; runs locally if present)"
fi

summary
