#!/usr/bin/env bash
# Unit tests for recover_env_branch (lib.sh): the teardown-recovery trust anchor.
#   A running job has its env's $ENVS mounted RW at /envstate, so it can overwrite the `branch`
#   file with any ref-valid name (e.g. a victim env's branch) to redirect reap-envs / ci-teardown
#   at a DIFFERENT env dir/tier. recover_env_branch rejects that by requiring
#   slugify(branch) == basename(envdir) — the dir name is set from the TRUSTED branch at create and
#   is NOT job-writable (a job writes inside the mount, it can't rename the dir). Symlinks refused too.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/harness.sh"
export CICD_BASE="$HERE/.."
# shellcheck source=/dev/null
. "$HERE/../bin/run-group.sh"     # _CICD_MAIN=0 -> functions only (pulls in lib.sh)

W="$(mktemp -d)"; ENVS="$W/envs"; mkdir -p "$ENVS"

# make an env dir named slugify(<branch>) holding a `branch` file with <content> (default = branch)
mk_env() {  # <branch> [content] -> echoes the dir
  local content="${2-$1}" d
  d="$ENVS/$(slugify "$1")"
  mkdir -p "$d"; printf '%s' "$content" > "$d/branch"; printf '%s' "$d"
}

suite "recover_env_branch — honest env recovers the EXACT branch"
# recover_env_branch validates via valid_branch (git check-ref-format). The CI test container
# (node:20-alpine) may lack git -> valid_branch fails -> honest recover returns empty. Skip there
# (in prod git is always present; a missing git makes it fail-SAFE = branch refused, teardown skipped).
if command -v git >/dev/null 2>&1; then
  d="$(mk_env dev)";      assert_eq "dev"        "$(recover_env_branch "$d")" "dev"
  d="$(mk_env prod)";     assert_eq "prod"       "$(recover_env_branch "$d")" "prod"
  d="$(mk_env feat/x_y)"; assert_eq "slash/ref"  "$(recover_env_branch "$d")" "feat/x_y"
else
  skip "honest recover_env_branch" "git not in this environment (valid_branch is host-only)"
fi

suite "recover_env_branch — REFUSE a job-forged branch (slug mismatch)"
# dir is slugify(dev) but the job overwrote branch -> 'prod' (a valid ref, wrong dir): the H1/F-A vector
d="$(mk_env dev prod)"
out="$(recover_env_branch "$d")"; rc=$?
assert_eq "forged prod-in-dev-dir -> rc1" "$rc"  "1"
assert_eq "forged -> no output"           "$out" ""
# forge to a victim branch that an operator map would alias to prod (e.g. 'main')
d="$(mk_env dev main)"
assert_fail "forged main-in-dev-dir refused" recover_env_branch "$d"

suite "recover_env_branch — REFUSE symlink / missing / invalid ref"
d="$ENVS/sl"; mkdir -p "$d"; ln -s /etc/hostname "$d/branch"
assert_fail "symlink branch refused"  recover_env_branch "$d"
d="$ENVS/mt"; mkdir -p "$d"
assert_fail "missing branch refused"  recover_env_branch "$d"
# invalid ref name stored in its OWN matching-slug dir -> still rejected by valid_branch
bad=".."; d="$ENVS/$(slugify "$bad")"; mkdir -p "$d"; printf '%s' "$bad" > "$d/branch"
assert_fail "invalid ref refused"     recover_env_branch "$d"
# empty branch file
d="$ENVS/em"; mkdir -p "$d"; : > "$d/branch"
assert_fail "empty branch refused"    recover_env_branch "$d"

rm -rf "$W"
summary
