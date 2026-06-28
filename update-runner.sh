#!/usr/bin/env bash
# update-runner.sh — refresh the WHOLE cicd-runner install from gitolite, in one shot.
# Run as ROOT (install ops are root's job; a separated admin can't reach git's dirs).
#
#   sudo /usr/local/sbin/cicd-update-runner <runner-repo-name> [--restart]
#
# Root runs the ROOT-OWNED installed copy, never ~cicd-runner/src/update-runner.sh (which a CI
# job, running as cicd-runner, could trojan -> root). This script refuses to run as root from a
# non-root-owned path and re-installs the root-owned entrypoint from the signature-verified tree
# on every run. BOOTSTRAP (one-time, as root, from a TRUSTED checkout — NOT the live ~/src):
#   git clone <runner-repo> /root/cicd-bootstrap && cd /root/cicd-bootstrap && git checkout <signed-release>
#   install -Dm755 -o root -g root ./update-runner.sh /usr/local/sbin/cicd-update-runner
#   sudo /usr/local/sbin/cicd-update-runner <runner-repo-name>
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

TRUSTED_ENTRYPOINT=/usr/local/sbin/cicd-update-runner

# CRITICAL (deploy escalation): the script ROOT executes must not be writable by any non-root
# user. ~cicd-runner/src is cicd-runner-owned, and CI jobs run AS cicd-runner — so a repo writer
# could overwrite ~cicd-runner/src/update-runner.sh and get ROOT the next time the operator runs
# `sudo update-runner`. UPDATE_REQUIRE_SIGNED can't stop that: it verifies the git BRANCH, not the
# on-disk file root is currently executing (the gate lives INSIDE the file under question). So
# root must invoke the installed, root-owned copy ($TRUSTED_ENTRYPOINT). Refuse any path whose
# file or ancestor dirs are non-root-owned or group/other-writable.
path_root_trusted() {  # <path>
  local p; p="$(readlink -f "$1" 2>/dev/null)" || return 1
  [ -n "$p" ] || return 1
  while :; do
    local own mode
    own="$(stat -c '%u' "$p" 2>/dev/null || stat -f '%u' "$p" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$p" 2>/dev/null || stat -f '%Lp' "$p" 2>/dev/null)" || return 1
    [ "$own" = 0 ] || return 1                       # must be owned by root
    [ "$(( 8#$mode & 0022 ))" -eq 0 ] || return 1    # reject group/other-writable
    [ "$p" = / ] && break
    p="$(dirname "$p")"
  done
}

# testability: `UPDATE_RUNNER_LIB=1 . update-runner.sh` loads the helpers above, runs nothing.
if [ -n "${UPDATE_RUNNER_LIB:-}" ]; then return 0 2>/dev/null || exit 0; fi

[ "$(id -u)" -eq 0 ] || { echo "update-runner: run as root" >&2; exit 1; }

REPO="${1:?usage: update-runner <runner-repo-name> [--restart]}"
RESTART=0; [ "${2:-}" = "--restart" ] && RESTART=1

if [ -z "${UPDATE_TRUST_OK:-}" ] && ! path_root_trusted "$0"; then
  echo "update-runner: REFUSING to run as root from a non-root-owned path:" >&2
  echo "    $0" >&2
  echo "  A non-root user can modify this file (e.g. a CI job running as cicd-runner), so running" >&2
  echo "  it as root is a privilege-escalation vector. Install + run the root-owned copy instead:" >&2
  echo "    sudo install -Dm755 -o root -g root '$0' $TRUSTED_ENTRYPOINT   # one-time, from a TRUSTED checkout" >&2
  echo "    sudo $TRUSTED_ENTRYPOINT $REPO" >&2
  echo "  (UPDATE_TRUST_OK=1 bypasses this only for an initial bootstrap from a root-owned clone.)" >&2
  exit 1
fi

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

# H4 leg-2 + deploy-escalation fix: snapshot the files ROOT installs/executes into a ROOT-OWNED
# dir NOW, straight from the just-extracted (signature-gated) $SRC — before dropping to the
# cicd-runner user for install.sh, so a cicd-runner foothold during install.sh cannot swap what
# root installs. This INCLUDES update-runner.sh itself: root must never execute/re-exec the
# cicd-runner-writable ~/src copy (a CI job could trojan it -> root). ~/src stays cicd-runner-owned
# (install.sh writes it); these snapshot copies + the installed entrypoint do not.
ROOTSNAP="$(mktemp -d)"; chmod 700 "$ROOTSNAP"
trap 'rm -rf "$ROOTSNAP"' EXIT
cp -f "$SRC/git/ci-job" "$ROOTSNAP/ci-job"
cp -f "$SRC/init/docker-rootless-cicd-runner.openrc" "$ROOTSNAP/openrc"
cp -f "$SRC/update-runner.sh" "$ROOTSNAP/update-runner.sh"

# Refresh the ROOT-OWNED entrypoint from the verified tree — the only copy root should ever run.
install -Dm755 -o root -g root "$ROOTSNAP/update-runner.sh" "$TRUSTED_ENTRYPOINT"

# Self-update: if update-runner.sh changed in this release, hand off to the freshly-installed
# ROOT-OWNED entrypoint (NOT ~/src) so it applies on THIS run without trusting a writable file.
# _UR_REEXEC guards the loop; UPDATE_TRUST_OK lets the re-exec'd root-owned copy pass the guard.
if [ -z "${_UR_REEXEC:-}" ]; then
  post="$( (sha256sum "$ROOTSNAP/update-runner.sh" 2>/dev/null || true) | cut -d' ' -f1)"
  if [ -n "$post" ] && [ "$post" != "$pre" ]; then
    echo "  update-runner.sh changed — re-exec'ing the root-owned $TRUSTED_ENTRYPOINT"
    exec env _UR_REEXEC=1 UPDATE_TRUST_OK=1 RUNNER_USER="$RUNNER_USER" GIT_USER="$GIT_USER" \
      BRANCH="$BRANCH" UPDATE_REQUIRE_SIGNED="${UPDATE_REQUIRE_SIGNED:-0}" \
      "$TRUSTED_ENTRYPOINT" "$@"
  fi
fi

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
