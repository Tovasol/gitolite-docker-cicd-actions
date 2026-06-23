#!/usr/bin/env bash
# run.sh — run the whole cicd-runner test suite (Tier 0 lint + Tier 1 unit + Tier 2
# adversarial). Emits a per-test NDJSON report (queryable with sq, like run meta) and a
# rollup. Exit nonzero if anything failed — so the CI `test` job goes red + emails.
#
#   cicd-runner/test/run.sh [report.ndjson]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="${1:-$HERE/report.ndjson}"; : > "$REPORT"
export CICD_TEST_REPORT="$REPORT"

fails=0
for t in lint.sh unit_lib.test.sh unit_meta.test.sh adversarial.test.sh; do
  [ -f "$HERE/$t" ] || continue
  bash "$HERE/$t" || fails=$((fails + 1))
done

printf '\n\033[1m═══ rollup ═══\033[0m  (%s)\n' "$REPORT"
if command -v sq >/dev/null 2>&1; then
  sq -H --tsv sql 'SELECT status, count(*) FROM data GROUP BY status ORDER BY status' < "$REPORT" 2>/dev/null \
    | while IFS=$'\t' read -r st n; do printf '  %-5s %s\n' "$st" "$n"; done
  echo "  --- failures ---"
  sq -H --tsv sql "SELECT suite, test, detail FROM data WHERE status='fail'" < "$REPORT" 2>/dev/null \
    | while IFS=$'\t' read -r s t d; do printf '  ✗ %s / %s — %s\n' "$s" "$t" "$d"; done
else
  for s in pass fail skip; do printf '  %-5s %s\n' "$s" "$(grep -c "\"status\":\"$s\"" "$REPORT" 2>/dev/null || echo 0)"; done
fi

[ "$fails" -eq 0 ] && { echo; echo "ALL SUITES PASSED"; } || { echo; echo "SUITES FAILED: $fails"; }
[ "$fails" -eq 0 ]
