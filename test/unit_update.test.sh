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

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

suite "path_root_trusted — owner gate (real root requirement)"
me="$(id -u)"
# trusted-uid VALUE is load-bearing: it must be exactly 0, not merely "not the caller's uid"
assert_ok   "prod comparator trusts only uid 0"   _prt_is_trusted_owner 0
assert_fail "prod comparator rejects uid 1"       _prt_is_trusted_owner 1
# a missing path canonicalizes to nothing -> reject (never trust what we can't stat)
assert_fail "missing path rejected"               path_root_trusted "$T/does-not-exist"
# Assertions that assume the CALLER is non-root (so a caller-owned file is NOT root-owned). The
# CI test container runs as root, where caller-owned == root-owned == trusted — skip there.
if [ "$me" != 0 ]; then
  printf '#!/bin/sh\n' > "$T/upd.sh"; chmod 755 "$T/upd.sh"
  assert_fail "non-root-owned file rejected"        path_root_trusted "$T/upd.sh"
  assert_fail "prod comparator rejects caller uid"  _prt_is_trusted_owner "$me"
else
  skip "non-root-caller owner-gate checks" "test runs as root (caller-owned == root-owned)"
fi

# To exercise the mode-mask, ancestor-walk and canonicalization (which the owner gate would
# otherwise short-circuit on a non-root host), hold the owner comparator constant: accept uid 0
# OR the test uid. Now root-owned SYSTEM ancestors (/, /var, ...) don't reject for the wrong
# reason, and the ONLY thing that can reject our caller-owned fixtures is the mode/ancestor/
# canonicalization logic under test — so a mutation that weakens it turns these red (the exact
# false-coverage the mutation pass found, where every fixture died at the owner gate first).
suite "path_root_trusted — mode + ancestor walk (owner-gate held constant)"
_prt_is_trusted_owner() { [ "${1:-}" = 0 ] || [ "${1:-}" = "$(id -u)" ]; }

# mode mask: a group/other-writable LEAF must reject (only the :45 `& 0022` mask can decide now)
base="$T/clean"; mkdir -p "$base/d"; chmod 0755 "$base" "$base/d"
printf '#!/bin/sh\n' > "$base/d/ww.sh"; chmod 0777 "$base/d/ww.sh"
assert_fail "other-writable leaf rejected"            path_root_trusted "$base/d/ww.sh"
printf '#!/bin/sh\n' > "$base/d/gw.sh"; chmod 0764 "$base/d/gw.sh"   # group-write only (0020 bit)
assert_fail "group-writable leaf rejected"            path_root_trusted "$base/d/gw.sh"

# ancestor walk: leaf + its dir clean, but a PARENT dir is world-writable -> only the walk rejects
anc="$T/anc"; mkdir -p "$anc/mid/leafdir"; printf '#!/bin/sh\n' > "$anc/mid/leafdir/x.sh"
chmod 0755 "$anc" "$anc/mid/leafdir" "$anc/mid/leafdir/x.sh"; chmod 0777 "$anc/mid"
assert_fail "world-writable ANCESTOR dir rejected"    path_root_trusted "$anc/mid/leafdir/x.sh"

# canonicalization: a symlink whose TARGET is writable must be followed + rejected (readlink -f)
tgt="$T/wtarget"; printf '#!/bin/sh\n' > "$tgt"; chmod 0777 "$tgt"
ln -s "$tgt" "$T/link.sh"
assert_fail "symlink to writable target rejected"     path_root_trusted "$T/link.sh"

# accept signal (catches an over-broad mask / always-reject mutation): a clean caller-owned file —
# but only meaningful if THIS host's tmp ancestor chain is itself non-writable (a 1777 /tmp on some
# CI would reject correctly), so gate the assertion on a clean-ancestors precondition.
acc="$T/acc"; mkdir -p "$acc"; printf '#!/bin/sh\n' > "$acc/ok.sh"; chmod 0755 "$T" "$acc" "$acc/ok.sh"
clean=1; q="$T"; while :; do am="$(stat -c '%a' "$q" 2>/dev/null || stat -f '%Lp' "$q" 2>/dev/null)"; [ "$(( 8#${am:-0} & 0022 ))" -eq 0 ] || { clean=0; break; }; [ "$q" = / ] && break; q="$(dirname "$q")"; done
[ "$clean" = 1 ] && assert_ok "clean caller-owned chain accepted" path_root_trusted "$acc/ok.sh"

# restore prod comparator; the same clean chain now FAILS (owner gate demands uid 0 again) —
# only meaningful when the caller is NON-root (under root, caller-owned IS root-owned == trusted).
_prt_is_trusted_owner() { [ "${1:-}" = 0 ]; }
if [ "$me" != 0 ]; then
  assert_fail "owner gate restored (uid-0) rejects caller-owned" path_root_trusted "$acc/ok.sh"
else
  skip "owner-gate-restored reject" "test runs as root (caller-owned == root-owned)"
fi

# sanity: LIB mode ran no deploy
assert_eq   "LIB mode ran no deploy"              "${REPO:-unset}" "unset"

summary
