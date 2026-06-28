#!/usr/bin/env bash
# Unit tests for fetch-tools' cache integrity (cache_ok): a poisoned shared /cache must not
# let a swapped tool pass as "cached". bin tools anchor to the script PIN (unforgeable);
# extracted tools anchor to the recorded installed-sha (tamper-evident).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/harness.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# load just the helpers (sha_of, cache_ok); the guard returns before the install loop.
# shellcheck source=/dev/null
CICD_TOOLS_DIR="$T" FETCH_TOOLS_LIB=1 . "$HERE/../bin/fetch-tools.sh"
set +e   # fetch-tools sets -e; the asserts below intentionally run failing commands

suite "fetch-tools cache_ok (re-verify installed binary)"

# --- bin tool: anchored to the script pin ---
printf 'GENUINE-YQ' > "$T/yq"; chmod +x "$T/yq"
pin="$(sha_of "$T/yq")"                         # for a bin tool, pin == installed sha
printf '%s' "$pin" > "$T/.yq.sha"
assert_ok   "bin: genuine binary -> cached"               cache_ok "$T/yq" "$T/.yq.sha" "$pin" bin

printf 'TROJAN-YQ' > "$T/yq"; chmod +x "$T/yq"           # attacker swaps the binary, marker stale
assert_fail "bin: swapped binary rejected (re-hash)"      cache_ok "$T/yq" "$T/.yq.sha" "$pin" bin

printf '%s' "$(sha_of "$T/yq")" > "$T/.yq.sha"           # attacker ALSO forges the marker
assert_fail "bin: forged marker still rejected (pin)"     cache_ok "$T/yq" "$T/.yq.sha" "$pin" bin

# --- extracted tool: anchored to the recorded installed sha ---
printf 'GENUINE-DUCK' > "$T/duckdb"; chmod +x "$T/duckdb"
printf '%s' "$(sha_of "$T/duckdb")" > "$T/.duckdb.sha"
assert_ok   "extracted: matches marker -> cached"         cache_ok "$T/duckdb" "$T/.duckdb.sha" archive-pin zip:duckdb

printf 'EVIL-DUCK' > "$T/duckdb"                          # swapped, marker stale
assert_fail "extracted: swapped binary rejected"          cache_ok "$T/duckdb" "$T/.duckdb.sha" archive-pin zip:duckdb

# --- missing / non-executable ---
assert_fail "missing binary -> not cached"                cache_ok "$T/nope" "$T/.nope.sha" deadbeef bin

summary
