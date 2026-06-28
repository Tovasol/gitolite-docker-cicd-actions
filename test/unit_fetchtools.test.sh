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

suite "fetch-tools cache trust (anchored to the unforgeable script pin)"

# --- bin tools: the installed binary IS the pinned artifact -> re-hash vs pin ---
printf 'GENUINE-YQ' > "$T/yq"; chmod +x "$T/yq"
pin="$(sha_of "$T/yq")"
assert_ok   "bin: genuine binary -> cached"             bin_cached "$T/yq" "$pin"
printf 'TROJAN-YQ' > "$T/yq"; chmod +x "$T/yq"          # swapped binary fails the pin
assert_fail "bin: swapped binary rejected"              bin_cached "$T/yq" "$pin"
printf 'X' > "$T/noexec"; chmod -x "$T/noexec"
assert_fail "bin: non-executable not cached"            bin_cached "$T/noexec" "$(sha_of "$T/noexec")"
assert_fail "bin: missing not cached"                   bin_cached "$T/nope" "$pin"

# --- extracted tools: anchored to the pinned ARCHIVE (M3) — a planted trojan binary/marker is
# irrelevant; the cache decision is the archive sha, and a forged archive can't match the pin.
printf 'REAL-DUCKDB-ARCHIVE-BYTES' > "$T/.duckdb.archive"
apin="$(sha_of "$T/.duckdb.archive")"
assert_ok   "extracted: archive matches pin -> cached"  archive_cached "$T/.duckdb.archive" "$apin"
printf 'TROJAN-ARCHIVE' > "$T/.duckdb.archive"          # forged archive -> different sha
assert_fail "extracted: forged archive rejected"        archive_cached "$T/.duckdb.archive" "$apin"
assert_fail "extracted: missing archive rejected"       archive_cached "$T/.nope.archive" "$apin"

summary
