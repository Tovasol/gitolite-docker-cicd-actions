#!/usr/bin/env sh
# CI self-test: run the runner's own test suite (Tier 0 lint + 1 unit + 2 adversarial)
# in-container on every push. The job is SELF-CONTAINED: it installs every dependency
# the tests need rather than assuming the image has them:
#   - ShellCheck (lint tier; from apt)
#   - yq         (run-group parses .gitolite/ci.yml with it -> unit_run needs it)
#   - duckdb     (ci-status analytics -> the adversarial corrupt-meta check)
# node (for the harness's JSON validation) + bash already ship in node:lts.
set -eu
. /cicd/lib.sh

step "satisfy test deps (VERBOSE diagnostics)"
echo "  whoami      : $(id -un 2>/dev/null) (uid $(id -u 2>/dev/null))"
echo "  uname -m    : $(uname -m)    dpkg-arch: $(dpkg --print-architecture 2>/dev/null || echo n/a)"
echo "  cwd         : $(pwd)"
echo "  PATH        : $PATH"
echo "  /cache      : $(ls -ld /cache 2>&1)"
echo "  /cache write: $( (touch /cache/.wtest 2>/dev/null && rm -f /cache/.wtest && echo yes) || echo 'NO (cannot write)' )"
echo "  ci/test.sh + fetch-tools come from the PUSHED tree -> version markers:"
echo "    fetch-tools is the new verified version? n_cached lines=$(grep -c n_cached bin/fetch-tools.sh 2>/dev/null || echo 0) (>=1 = new code)"

if command -v apt-get >/dev/null 2>&1; then
  # Plain apt — the RUNNER makes apt work under hardened rootless docker (DESIGN §35:
  # APT::Sandbox::User=root conf + tmpfs at apt's cache/lists), so jobs need no workaround.
  retry -n 3 -d 5 -- apt-get update -qq || echo "  WARN: apt-get update failed"
  # git: lets the host-only branch-validation tests (valid_branch F3, recover_env_branch honest
  # cases) run for REAL in CI instead of skipping — it backs `git check-ref-format` (the ref
  # sanitizer that gates teardown env/key mapping). Without it those cases self-skip (fail-safe).
  apt-get install -y -qq --no-install-recommends shellcheck curl unzip ca-certificates git \
    || echo "  WARN: apt install failed - lint tier may skip"
fi
echo "  curl=$(command -v curl || echo NO)  unzip=$(command -v unzip || echo NO)  shellcheck=$(command -v shellcheck || echo NO)  git=$(command -v git || echo NO)"
# egress check (now that curl is installed) — the prime suspect if fetch-tools fails on the VPS
if command -v curl >/dev/null 2>&1; then
  echo "  net github  : $(curl -fsS -m 15 -o /dev/null -w 'HTTP %{http_code} in %{time_total}s' https://github.com 2>&1 || echo 'UNREACHABLE (no egress?)')"
  echo "  net yq-url  : $(curl -fsSI -m 15 -o /dev/null -w 'HTTP %{http_code}' https://github.com/mikefarah/yq/releases/download/v4.47.1/yq_linux_amd64 2>&1 || echo 'UNREACHABLE')"
fi

# yq + duckdb: PINNED + sha256-VERIFIED into the persistent /cache volume (cached).
CICD_TOOLS_DIR="/cache/tools"; export CICD_TOOLS_DIR
echo "  --- fetch-tools output (verbatim) ---"
rc=0; sh bin/fetch-tools.sh yq duckdb || rc=$?
[ "$rc" = 0 ] && echo "  --- fetch-tools exit 0 ---" || echo "  --- fetch-tools FAILED (exit $rc) ---"
echo "  ls $CICD_TOOLS_DIR : $(ls -la "$CICD_TOOLS_DIR" 2>&1)"

case ":$PATH:" in *":$CICD_TOOLS_DIR:"*) ;; *) PATH="$CICD_TOOLS_DIR:$PATH"; export PATH ;; esac
for t in shellcheck yq duckdb node bash; do
  printf '  resolve %-10s %s\n' "$t" "$(command -v "$t" 2>/dev/null || echo MISSING)"
done
yq --version 2>&1 | sed 's/^/  yq says: /' || echo "  yq: NOT RUNNABLE"
command -v bash >/dev/null 2>&1 || die "bash required to run the test harness, not found in image"

step "run runner test suite"
# run.sh exits nonzero if any test fails -> this job goes red -> notify-email fires.
bash test/run.sh
