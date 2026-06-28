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
#   4) gitolite ci-job command (the post-receive HOOK is managed in gitolite-admin, not here)
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
BRANCH="${BRANCH:-release}"              # deploy from the promoted, admin-PROTECTED release branch
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

# H4 — integrity gate. This script extracts the runner-repo tree and runs/installs it AS ROOT,
# so whoever can push $BRANCH effectively gets root here. Two defenses, both operator-owned:
#   * PROTECT the deploy branch (admin-only) — see SECURITY.md.
#   * UPDATE_REQUIRE_SIGNED=1 + import the trusted signer's key into root's gpg keyring; we then
#     verify the $BRANCH tip is a valid signed commit before touching anything.
if [ "${UPDATE_REQUIRE_SIGNED:-0}" = 1 ]; then
  if git --git-dir="$RUNNER_REPO" verify-commit "$BRANCH" >/dev/null 2>&1; then
    echo "  verified: $BRANCH tip is a trusted signed commit"
  else
    echo "update-runner: REFUSING — $BRANCH tip is not a valid SIGNED commit (UPDATE_REQUIRE_SIGNED=1)." >&2
    echo "               import the signer's key into root's gpg keyring, or unset to deploy unverified." >&2
    exit 1
  fi
else
  echo "  WARNING: deploying UNVERIFIED '$BRANCH' — anyone who can push it gets ROOT on this host." >&2
  echo "           Protect the deploy branch (admin-only) and set UPDATE_REQUIRE_SIGNED=1 with a trusted key." >&2
fi

echo "→ [1/5] source ← $RUNNER_REPO ($BRANCH)"
SRC="$RUN/src"
# Guard the path before any rm/mv (a wrong/empty $RUN must never delete arbitrary dirs):
case "$RUN" in /home/*|/var/lib/*) ;; *) echo "update-runner: refusing unexpected runner home '$RUN'" >&2; exit 1 ;; esac
[ "$(basename "$SRC")" = src ] || { echo "update-runner: refusing src path '$SRC'" >&2; exit 1; }
# Capture the running updater's hash BEFORE we overwrite ~/src, so we can detect a self-update.
SELF="$SRC/update-runner.sh"
pre=""; [ -f "$SELF" ] && pre="$( (sha256sum "$SELF" 2>/dev/null || true) | cut -d' ' -f1)"
# Atomic-swap refresh: extract into a staging dir, then RENAME into place. The live ~/src is
# renamed to ~/src.prev (never deleted in place -> instant rollback), and the only rm targets
# are uniquely-suffixed derived paths. This also drops files deleted upstream (no ghosts) —
# unlike a `tar -x` overlay onto the existing tree, which leaves stale files behind.
STAGE="$SRC.stage.$$"
sudo -u "$RUNNER_USER" rm -rf -- "$STAGE"
sudo -u "$RUNNER_USER" mkdir -p -- "$STAGE"
git --git-dir="$RUNNER_REPO" archive "$BRANCH" | sudo -u "$RUNNER_USER" tar -x -C "$STAGE"
sudo -u "$RUNNER_USER" rm -rf -- "$SRC.prev"
[ -d "$SRC" ] && sudo -u "$RUNNER_USER" mv -- "$SRC" "$SRC.prev"
sudo -u "$RUNNER_USER" mv -- "$STAGE" "$SRC"

# Self-update: if update-runner.sh itself changed in this release, hand off to the new copy so
# it applies on THIS run (ends the "run it twice" chicken-and-egg). _UR_REEXEC guards a loop.
if [ -z "${_UR_REEXEC:-}" ] && [ -f "$SELF" ]; then
  post="$( (sha256sum "$SELF" 2>/dev/null || true) | cut -d' ' -f1)"
  if [ -n "$post" ] && [ "$post" != "$pre" ]; then
    echo "  update-runner.sh changed in this release — re-exec'ing the new version"
    exec env _UR_REEXEC=1 RUNNER_USER="$RUNNER_USER" GIT_USER="$GIT_USER" BRANCH="$BRANCH" \
      UPDATE_REQUIRE_SIGNED="${UPDATE_REQUIRE_SIGNED:-0}" "$SELF" "$@"
  fi
fi

# H4 leg-2: snapshot the files ROOT installs into a root-owned dir NOW, before dropping to the
# cicd-runner user for install.sh — so a cicd-runner foothold during install.sh cannot swap what
# root installs. ~/src stays cicd-runner-owned (install.sh writes it); these snapshot copies do not.
ROOTSNAP="$(mktemp -d)"; chmod 700 "$ROOTSNAP"
trap 'rm -rf "$ROOTSNAP"' EXIT
cp -f "$SRC/git/ci-job" "$ROOTSNAP/ci-job"
cp -f "$SRC/init/docker-rootless-cicd-runner.openrc" "$ROOTSNAP/openrc"

echo "→ [2/5] install.sh (scripts + dirs)"
sudo -iu "$RUNNER_USER" bash -lc 'cd ~/src && ./install.sh'

echo "→ [3/5] crontab"
# some cron implementations stage a temp file under ~/.cache; ensure it exists first.
sudo -iu "$RUNNER_USER" bash -lc 'mkdir -p ~/.cache && crontab ~/src/crontab.sample'

echo "→ [4/5] ci-job command (+ enable + sudo grant)"
# NOTE: the post-receive CI hook is NOT installed here. It's managed declaratively in
# the gitolite-admin repo as local/hooks/repo-specific/cicd, wired via
# `option hook.post-receive = echo cicd` in conf/gitolite.conf, and deployed by pushing
# gitolite-admin (gitolite distributes it to all repos, now + future). bin/post-receive
# is the canonical source — re-sync the gitolite-admin copy if it ever changes.
LOCAL_CODE="$(sudo -u "$GIT_USER" gitolite query-rc LOCAL_CODE)"
# ci-job: the git-side gitolite command (run/status/log over ssh, gitolite-authz, §34).
install -Dm755 "$ROOTSNAP/ci-job" "$LOCAL_CODE/commands/ci-job"   # from the root-owned snapshot (H4)
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
install -m755 "$ROOTSNAP/openrc" /etc/init.d/docker-rootless-cicd-runner   # from the root-owned snapshot (H4)

if [ "$RESTART" -eq 1 ]; then
  echo "→ restart docker-rootless-cicd-runner (bounces docker, KILLS in-flight builds)"
  rc-service docker-rootless-cicd-runner restart
else
  echo "  init file copied — run with --restart to apply (bounces docker). Skipped."
fi

# drain anything deferred while the env was not ready (deferred-recovery, §10.6/§33)
sudo -iu "$RUNNER_USER" bash -lc '~/runner/bin/ci-recover' >/dev/null 2>&1 || true

echo "UPDATE OK"
