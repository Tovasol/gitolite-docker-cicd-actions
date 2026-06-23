#!/usr/bin/env bash
# update-runner.sh — refresh the WHOLE cicd-runner install from gitolite, in one shot.
# Run as ROOT (install ops are root's job; a separated admin can't reach git's dirs).
#
#   sudo /home/cicd-runner/src/update-runner.sh <runner-repo-name> [--restart]
#
# Updates everything regardless of what changed:
#   1) source (archive-push out of the bare repo — same mechanism the system uses)
#   2) scripts + dirs           (install.sh — guards runner.conf, seeds slots)
#   3) crontab                  (new schedules, e.g. the */10 ci-recover backstop)
#   4) gitolite post-receive    hook
#   5) boot/init service FILE   (copy only; takes effect on --restart)
#
# Idempotent. Does NOT re-post the ramfs key (survives updates; only reboot wipes it).
# In-flight builds survive (install swaps inodes; a running run-group keeps its copy).
# --restart bounces rootless docker (KILLS in-flight builds) — use only when the init
# script itself changed.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "update-runner: run as root" >&2; exit 1; }

REPO="${1:?usage: update-runner <runner-repo-name> [--restart]}"
RESTART=0; [ "${2:-}" = "--restart" ] && RESTART=1

RUNNER_USER="${RUNNER_USER:-cicd-runner}"
GIT_USER="${GIT_USER:-git}"
BRANCH="${BRANCH:-main}"                 # gitolite HEAD may be 'master'; we pushed 'main'
RUN="$(getent passwd "$RUNNER_USER" | cut -d: -f6)"
GIT_HOME="$(getent passwd "$GIT_USER" | cut -d: -f6)"
[ -n "$RUN" ]      || { echo "no home for user $RUNNER_USER" >&2; exit 1; }
[ -n "$GIT_HOME" ] || { echo "no home for user $GIT_USER" >&2; exit 1; }

# accept a bare repo name OR a full path to the bare repo
case "$REPO" in
  /*) RUNNER_REPO="$REPO" ;;
  *)  RUNNER_REPO="$GIT_HOME/repositories/${REPO%.git}.git" ;;
esac
[ -d "$RUNNER_REPO" ] || { echo "no bare repo at $RUNNER_REPO" >&2; exit 1; }

echo "→ [1/5] source ← $RUNNER_REPO ($BRANCH)"
git --git-dir="$RUNNER_REPO" archive "$BRANCH" cicd-runner \
  | sudo -u "$RUNNER_USER" tar -x --strip-components=1 -C "$RUN/src"

echo "→ [2/5] install.sh (scripts + dirs)"
sudo -iu "$RUNNER_USER" bash -lc 'cd ~/src && ./install.sh'

echo "→ [3/5] crontab"
# some cron implementations stage a temp file under ~/.cache; ensure it exists first.
sudo -iu "$RUNNER_USER" bash -lc 'mkdir -p ~/.cache && crontab ~/src/crontab.sample'

echo "→ [4/5] gitolite hook + ci-job command (+ enable + sudo grant)"
LOCAL_CODE="$(sudo -u "$GIT_USER" gitolite query-rc LOCAL_CODE)"
install -Dm755 "$RUN/runner/bin/post-receive" "$LOCAL_CODE/hooks/common/post-receive"
# ci-job: the git-side gitolite command (run/status/log over ssh, gitolite-authz, §34).
install -Dm755 "$RUN/src/git/ci-job" "$LOCAL_CODE/commands/ci-job"
chown -R "$GIT_USER:$GIT_USER" "$LOCAL_CODE"

# enable ci-job in gitolite.rc (idempotent) so `ssh git@host ci-job …` is allowed
GIT_HOME="$(getent passwd "$GIT_USER" | cut -d: -f6)"
RCF="$GIT_HOME/.gitolite.rc"
if [ -f "$RCF" ] && ! grep -q "'ci-job'" "$RCF"; then
  sudo -u "$GIT_USER" sed -i "s/ENABLE => \[/ENABLE => [ 'ci-job',/" "$RCF" \
    && echo "  enabled 'ci-job' in gitolite.rc" \
    || echo "  WARN: could not auto-enable ci-job — add 'ci-job' to the ENABLE list in $RCF"
fi
sudo -u "$GIT_USER" -H gitolite setup >/dev/null 2>&1 || true   # recompile (hooks + rc)

# read-side sudo grant for ci-job's status/log/run-watch proxy (+ the cicd-ingest write
# bridge). Deterministic + VALIDATED before it lands, so a bad file can never break sudo.
B="$RUN/runner/bin"
_su="$(mktemp)"
cat > "$_su" <<EOF
$GIT_USER ALL=($RUNNER_USER) NOPASSWD: $B/cicd-ingest, $B/ci-status, $B/ci-log, $B/ci-runs
Defaults!$B/cicd-ingest,$B/ci-status,$B/ci-log,$B/ci-runs !requiretty
EOF
if visudo -cf "$_su" >/dev/null 2>&1; then
  install -m440 "$_su" /etc/sudoers.d/cicd-runner
  echo "  sudoers: $GIT_USER -> $RUNNER_USER (cicd-ingest + ci-status/ci-log/ci-runs)"
else
  echo "  WARN: generated sudoers failed validation — NOT installed (check $B paths)" >&2
fi
rm -f "$_su"

echo "→ [5/5] boot/init service file"
install -m755 "$RUN/src/init/docker-rootless-cicd-runner.openrc" \
        /etc/init.d/docker-rootless-cicd-runner

if [ "$RESTART" -eq 1 ]; then
  echo "→ restart docker-rootless-cicd-runner (bounces docker, KILLS in-flight builds)"
  rc-service docker-rootless-cicd-runner restart
else
  echo "  init file copied — run with --restart to apply (bounces docker). Skipped."
fi

# drain anything deferred while the env was not ready (deferred-recovery, §10.6/§33)
sudo -iu "$RUNNER_USER" bash -lc '~/runner/bin/ci-recover' >/dev/null 2>&1 || true

echo "UPDATE OK"
