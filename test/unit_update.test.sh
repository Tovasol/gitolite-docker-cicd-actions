#!/usr/bin/env bash
# Unit test for update-runner.sh's deploy-escalation guard: root must never execute the script
# from a path a non-root user can modify (e.g. ~cicd-runner/src, writable by CI jobs that run AS
# cicd-runner). path_root_trusted() must reject a non-root-owned / group-or-other-writable path
# (file OR any ancestor dir) and accept a clean root-only chain. Sourced in LIB mode (no deploy).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/harness.sh"
# shellcheck source=/dev/null
UPDATE_RUNNER_LIB=1 . "$HERE/../update-runner.sh"

suite "path_root_trusted (deploy-escalation guard)"

# We cannot chown to root in CI, so verify the REJECT paths (the security-critical direction):
# any user-writable file or ancestor must be refused. On the prod host the file + chain are
# root:root 0755, which path_root_trusted accepts (the accept direction is exercised live).
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# a file the current (non-root) user owns -> not root-owned -> reject
printf '#!/bin/sh\n' > "$T/upd.sh"; chmod 755 "$T/upd.sh"
assert_fail "non-root-owned file rejected"        path_root_trusted "$T/upd.sh"

# group/other-writable file (even if it were root-owned, write bits are disqualifying)
printf '#!/bin/sh\n' > "$T/ww.sh"; chmod 0777 "$T/ww.sh"
assert_fail "world-writable file rejected"        path_root_trusted "$T/ww.sh"

# a missing path resolves to nothing -> reject (never trust what we can't stat)
assert_fail "missing path rejected"               path_root_trusted "$T/does-not-exist"

# the ancestor chain matters: a file under a user-owned dir is reachable-to-tamper -> reject
mkdir -p "$T/sub"; printf '#!/bin/sh\n' > "$T/sub/x.sh"; chmod 755 "$T/sub/x.sh" "$T/sub"
assert_fail "file under non-root dir rejected"    path_root_trusted "$T/sub/x.sh"

# sanity: the function is pure (no side effects, no deploy ran because LIB mode returned early)
assert_eq   "LIB mode ran no deploy"              "${REPO:-unset}" "unset"

summary
