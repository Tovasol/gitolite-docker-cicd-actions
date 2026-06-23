#!/usr/bin/env bash
# harness.sh — tiny zero-dependency bash test framework. `source` it in a *.test.sh.
# No bats, no external deps (fits the hand-rolled ethos; runs in any bash incl. the CI
# container). Emits human lines + an NDJSON result stream (dogfoods our own seam: the
# test report is queryable with sq, exactly like run meta).
#
# Provides: assert_eq, assert_ne, assert_match, assert_no_match, assert_ok, assert_fail,
#           assert_json, ok, fail, skip, suite, summary.   Counts in _T_PASS/_T_FAIL/_T_SKIP.
_T_PASS=0; _T_FAIL=0; _T_SKIP=0; _T_SUITE="${_T_SUITE:-$(basename "${0%.test.sh}")}"
_T_REPORT="${CICD_TEST_REPORT:-}"           # optional NDJSON sink (set by run.sh)

_t_esc() { printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/ /g'; }
_t_log() {  # <name> <status:pass|fail|skip> <detail>
  [ -z "$_T_REPORT" ] && return 0
  printf '{"suite":"%s","test":"%s","status":"%s","detail":"%s"}\n' \
    "$(_t_esc "$_T_SUITE")" "$(_t_esc "$1")" "$2" "$(_t_esc "${3:-}")" >> "$_T_REPORT"
}
ok()   { _T_PASS=$((_T_PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; _t_log "$1" pass ""; }
fail() { _T_FAIL=$((_T_FAIL+1)); printf '  \033[31m✗ %s\033[0m\n      %s\n' "$1" "${2:-}"; _t_log "$1" fail "${2:-}"; }
skip() { _T_SKIP=$((_T_SKIP+1)); printf '  \033[2m- %s (skip: %s)\033[0m\n' "$1" "${2:-}"; _t_log "$1" skip "${2:-}"; }
suite(){ _T_SUITE="$1"; printf '\n\033[1m# %s\033[0m\n' "$1"; }

assert_eq()       { [ "$2" = "$3" ] && ok "$1" || fail "$1" "got [$2] want [$3]"; }            # <name> <got> <want>
assert_ne()       { [ "$2" != "$3" ] && ok "$1" || fail "$1" "got [$2] should differ from [$3]"; }
assert_match()    { printf '%s' "$2" | grep -qE -- "$3" && ok "$1" || fail "$1" "[$2] !~ /$3/"; }  # <name> <str> <re>
assert_no_match() { printf '%s' "$2" | grep -qE -- "$3" && fail "$1" "[$2] =~ /$3/ (should not)" || ok "$1"; }
assert_ok()       { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else fail "$1" "cmd exited nonzero: ${*:2}"; fi; }   # <name> <cmd...>
assert_fail()     { if "${@:2}" >/dev/null 2>&1; then fail "$1" "cmd unexpectedly succeeded: ${*:2}"; else ok "$1"; fi; }
assert_json() {  # <name> <string>   — valid JSON? (node|python3|sq, else skip)
  local s="$2"
  if command -v node >/dev/null 2>&1; then
    node -e 'JSON.parse(process.argv[1])' "$s" >/dev/null 2>&1 && ok "$1" || fail "$1" "invalid JSON: $s"
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$s" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1 && ok "$1" || fail "$1" "invalid JSON: $s"
  elif command -v sq >/dev/null 2>&1; then
    printf '%s' "$s" | sq -H --tsv sql 'SELECT 1 FROM data LIMIT 1' >/dev/null 2>&1 && ok "$1" || fail "$1" "invalid JSON: $s"
  else skip "$1" "no JSON validator (node/python3/sq)"; fi
}
summary() {  # print + exit code: 0 if no failures
  printf '\n\033[1m%s:\033[0m %d passed, %d failed, %d skipped\n' "$_T_SUITE" "$_T_PASS" "$_T_FAIL" "$_T_SKIP"
  [ "$_T_FAIL" -eq 0 ]
}
