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

mkdir -p "$BASE"/{bin,etc,lib,queue,runs,cache,envs,slots,incoming}
install -m755 "$SRC/bin/"* "$BASE/bin/"
install -m644 "$SRC/lib/"* "$BASE/lib/"      # in-container helpers (mounted ro as /cicd/lib.sh)
# strip the .sample suffix on the wall notifier so it's runnable if referenced
[ -f "$BASE/bin/notify-wall.sample" ] && mv -f "$BASE/bin/notify-wall.sample" "$BASE/bin/notify-wall" && chmod +x "$BASE/bin/notify-wall"

# config: prefer system-wide; fall back to per-base
if [ ! -f "$BASE/etc/runner.conf" ] && [ ! -f "$CONF_SYS" ]; then
  sed "s#__UID__#$(id -u)#; s#^RUNNER_BASE=.*#RUNNER_BASE=$BASE#" \
    "$SRC/etc/runner.conf.sample" > "$BASE/etc/runner.conf"
  echo "Wrote $BASE/etc/runner.conf — REVIEW IT (DOCKER_HOST, RESOURCE_LIMITS, NOTIFY_CMD…)."
  echo "Stays user-local; no sudo/no /etc needed. The git hook is self-contained and never reads it."
fi

# seed slot files for the global concurrency cap
. "$BASE/etc/runner.conf" 2>/dev/null || . "$CONF_SYS" 2>/dev/null || true
for i in $(seq 1 "${MAX_JOBS:-4}"); do : > "$BASE/slots/$i"; done

# user-local tools (sops/yq/age) into ~/.local/bin — no root, no /usr/local
LOCAL_BIN="${LOCAL_BIN:-$HOME/.local/bin}"; mkdir -p "$LOCAL_BIN"
case ":$PATH:" in *":$LOCAL_BIN:"*) ;; *)
  grep -qs "$LOCAL_BIN" ~/.bash_profile 2>/dev/null || \
    echo "export PATH=\"$LOCAL_BIN:\$PATH\"" >> ~/.bash_profile
  export PATH="$LOCAL_BIN:$PATH" ;;
esac
echo "Fetching user-local tools into $LOCAL_BIN …"
LOCAL_BIN="$LOCAL_BIN" "$SRC/bin/fetch-tools.sh" || echo "  (fetch-tools failed — install sops/yq/age into $LOCAL_BIN manually)"

# preflight
echo "--- preflight ---"
command -v yq    >/dev/null && echo "yq:    $(command -v yq)"      || echo "MISSING: yq    — run $SRC/bin/fetch-tools.sh"
command -v sops  >/dev/null && echo "sops:  $(command -v sops)"    || echo "MISSING: sops  — run $SRC/bin/fetch-tools.sh"
command -v age-keygen >/dev/null && echo "age:   $(command -v age-keygen)" || echo "MISSING: age   — run $SRC/bin/fetch-tools.sh"
command -v docker>/dev/null && (docker info >/dev/null 2>&1 && echo "docker: rootless OK" || echo "docker present but daemon unreachable (rootless running? DOCKER_HOST set?)") || echo "MISSING: docker (system runtime)"
command -v flock >/dev/null && echo "flock: ok" || echo "MISSING: flock (sys-apps/util-linux — usually already present)"

cat <<EOF

Next (as root):
  1. Gitolite hook + sudo bridge (SOP §2.6):
       install -Dm755 $BASE/bin/post-receive ~git/local/hooks/common/post-receive
       # ~git/.gitolite.rc needs:  LOCAL_CODE => "\$ENV{HOME}/local",
       printf 'git ALL=(%s) NOPASSWD: %s/bin/cicd-ingest\nDefaults!%s/bin/cicd-ingest !requiretty\n' \
         "$(id -un)" "$BASE" "$BASE" > /etc/sudoers.d/cicd-runner
       chmod 440 /etc/sudoers.d/cicd-runner && visudo -cf /etc/sudoers.d/cicd-runner
       sudo -u git gitolite setup --hooks-only
       # (no chmod on cicd-runner's home needed: sudo execs run-group AS cicd-runner,
       #  who owns + can traverse its own 700 home; sudo's pre-exec stat runs as root.)
  2. (config stays user-local at $BASE/etc/runner.conf — no /etc copy, no sudo)
  3. Crontab (as $(id -un)):     crontab $SRC/crontab.sample
  4. ramfs key + unlock:         SOP §2.3 / §3, then: unlock-ci && ci-status
EOF
