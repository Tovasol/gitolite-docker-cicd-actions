#!/usr/bin/env bash
# install.sh — lay down the cicd-runner on a host. Run as the cicd-runner user
# (NOT root) after rootless docker is working. Idempotent.
#
#   git clone <this repo> && cd cicd-runner && ./install.sh
#
# Then (as root) install the gitolite hook + crontab; see README.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
BASE="${RUNNER_BASE_OVERRIDE:-$HOME/runner}"
CONF_SYS="/etc/cicd-runner/runner.conf"

echo "Installing cicd-runner into $BASE (user: $(id -un), uid: $(id -u))"

mkdir -p "$BASE"/{bin,etc,queue,runs,cache,envs,slots}
install -m755 "$SRC/bin/"* "$BASE/bin/"
# strip the .sample suffix on the wall notifier so it's runnable if referenced
[ -f "$BASE/bin/notify-wall.sample" ] && mv -f "$BASE/bin/notify-wall.sample" "$BASE/bin/notify-wall" && chmod +x "$BASE/bin/notify-wall"

# config: prefer system-wide; fall back to per-base
if [ ! -f "$CONF_SYS" ] && [ ! -f "$BASE/etc/runner.conf" ]; then
  sed "s#__UID__#$(id -u)#; s#^RUNNER_BASE=.*#RUNNER_BASE=$BASE#" \
    "$SRC/etc/runner.conf.sample" > "$BASE/etc/runner.conf"
  echo "Wrote $BASE/etc/runner.conf — REVIEW IT (paths, MAX_JOBS, TRUSTED_BRANCHES, NOTIFY_CMD)."
  echo "Tip: 'sudo install -Dm644 $BASE/etc/runner.conf $CONF_SYS' to make it system-wide"
  echo "     (the gitolite hook, run as the git user, reads /etc/cicd-runner/runner.conf)."
fi

# seed slot files for the global concurrency cap
. "$BASE/etc/runner.conf" 2>/dev/null || . "$CONF_SYS"
for i in $(seq 1 "${MAX_JOBS:-4}"); do : > "$BASE/slots/$i"; done

# preflight
echo "--- preflight ---"
command -v yq    >/dev/null && echo "yq:    $(yq --version)"     || echo "MISSING: yq (mikefarah v4) — emerge app-admin/yq or download binary"
command -v sops  >/dev/null && echo "sops:  $(sops --version)"   || echo "MISSING: sops"
command -v age   >/dev/null && echo "age:   $(age --version)"    || echo "MISSING: age"
command -v docker>/dev/null && (docker info >/dev/null 2>&1 && echo "docker: rootless OK" || echo "docker present but daemon unreachable (rootless running? DOCKER_HOST set?)") || echo "MISSING: docker"
command -v flock >/dev/null && echo "flock: ok" || echo "MISSING: flock (util-linux)"

cat <<EOF

Next (as root):
  1. Gitolite hook:
       install -Dm755 $BASE/bin/post-receive ~git/local/hooks/common/post-receive
       # ensure ~git/.gitolite.rc has:  LOCAL_CODE => "\$ENV{HOME}/local",
       # ensure the hook can find the runner: export CICD_BASE=$BASE for the git user,
       #   or it defaults to /home/cicd-runner/runner.
       sudo -u git gitolite setup --hooks-only
  2. Make config readable by the git user (hook runs as git):
       install -Dm644 $BASE/etc/runner.conf $CONF_SYS
  3. Crontab (as cicd-runner):  crontab $SRC/crontab.sample
  4. ramfs key + unlock:        see CI-RUNNER-SOP.md §2.3 / §3, then: unlock-ci && ci-status
EOF
