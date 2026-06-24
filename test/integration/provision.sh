#!/usr/bin/env bash
# Build-time provisioning: stand up the REAL control plane inside the image.
#   gitolite (git user) + test repos with per-user access  ->  archive-push + hook
#   cicd-runner (runner installed) + sudo bridge + ci-job gitolite command
# docker is already mocked (the isolation black box). Runs as root during image build.
set -eux
SRC=/opt/cicd-src
GH=/home/git
B=/home/cicd-runner/runner/bin

# mock-docker control files (world-writable so scenarios can flip docker up/down + job rc)
mkdir -p /tmp/mockdocker; printf 0 > /tmp/mockdocker/info_rc; printf 0 > /tmp/mockdocker/run_rc
chmod -R 777 /tmp/mockdocker

# ---- gitolite for the git user ---------------------------------------------------------
ssh-keygen -t ed25519 -N '' -f /tmp/admin -C admin >/dev/null
install -o git -g git -m644 /tmp/admin.pub "$GH/admin.pub"
sudo -u git -H bash -lc 'cd ~ && gitolite setup -pk admin.pub'
# enable our gitolite.rc needs: LOCAL_CODE (for hook+command) + ci-job in ENABLE
sudo -u git -H bash -lc '
  rc=~/.gitolite.rc
  # guard on an ACTIVE (uncommented) entry — the stock rc ships commented `# LOCAL_CODE`
  # hint lines, so a plain `grep LOCAL_CODE` matches those and the insert never happens.
  grep -qE "^[[:space:]]*LOCAL_CODE" "$rc" || sed -i "s|%RC = (|%RC = (\n    LOCAL_CODE => \"\$ENV{HOME}/local\",|" "$rc"
  grep -qE "^[[:space:]]*ENABLE.*'\''ci-job'\''" "$rc" || sed -i "s|ENABLE => \[|ENABLE => [ '\''ci-job'\'',|" "$rc"
'
# define repos + per-user access. Drive gitolite the NON-ssh way: append the live conf and
# `gitolite compile`. (A local `git push` to gitolite-admin can't work — gitolite's update
# hook derives the repo from GL_REPO, which only gitolite-shell sets over ssh; locally it is
# '\'''\'' -> FATAL "invalid repo ''\'''\''". Scenarios call ci-job directly with GL_USER set, so no
# ssh keys are needed — only the compiled access rules.)
sudo -u git -H bash -lc '
  set -eux
  git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch master
  cat >> ~/.gitolite/conf/gitolite.conf <<CONF

repo app
    RW+ = alice
    R   = bob

repo lib
    RW+ = bob
    R   = alice
CONF
  gitolite compile
  gitolite trigger POST_COMPILE
'

# ---- cicd-runner: install the runner -------------------------------------------------
sudo -u cicd-runner -H bash -lc "cd $SRC && RUNNER_BASE_OVERRIDE=/home/cicd-runner/runner LOCAL_BIN=/usr/local/bin ./install.sh" || true
sudo -u cicd-runner -H bash -lc 'mkdir -p ~/runner/{queue,runs,incoming,envs,cache,slots}; for i in 1 2 3 4; do : > ~/runner/slots/$i; done'
printf fakekey > /home/cicd-runner/.fakekey; chown cicd-runner:cicd-runner /home/cicd-runner/.fakekey
# A SUPERSET of what run-group needs under `set -u` — every DEFAULT_* the executor reads
# without a literal fallback must exist here (run-group dies "DEFAULT_TIMEOUT: unbound
# variable" otherwise). Mirrors etc/runner.conf.sample, overriding only the sandbox bits
# (alpine image, mock docker socket, fake age key, no notify, no cgroup limits).
cat > /home/cicd-runner/runner/etc/runner.conf <<CONF
RUNNER_USER=cicd-runner
RUNNER_BASE=/home/cicd-runner/runner
GIT_REPO_BASE=/home/git/repositories
MAX_JOBS=4
SLOT_WAIT_SECS=1
RESOURCE_LIMITS=0
DEFAULT_IMAGE=alpine
DEFAULT_TIMEOUT=900
DEFAULT_MEMORY=2g
DEFAULT_PIDS=512
DEFAULT_NETWORK=none
DOCKER_HOST=unix:///mock.sock
SOPS_AGE_KEY_FILE=/home/cicd-runner/.fakekey
SHM_DIR=/dev/shm
LOCAL_BIN=/usr/local/bin
NOTIFY_CMD=
NOTIFY_BACKSTOP=0
CONF
chown cicd-runner:cicd-runner /home/cicd-runner/runner/etc/runner.conf

# ---- the bridge: hook + ci-job command + sudoers -------------------------------------
LOCAL_CODE="$(sudo -u git -H gitolite query-rc LOCAL_CODE)"
[ -n "$LOCAL_CODE" ] || { echo "LOCAL_CODE empty - gitolite.rc not set"; exit 1; }
install -Dm755 "$B/post-receive" "$LOCAL_CODE/hooks/common/post-receive.h50-cicd"
install -Dm755 "$SRC/git/ci-job" "$LOCAL_CODE/commands/ci-job"
chown -R git:git "$LOCAL_CODE"
sudo -u git -H gitolite setup --hooks-only
cat > /etc/sudoers.d/cicd-runner <<EOF
git ALL=(cicd-runner) NOPASSWD: $B/cicd-ingest, $B/ci-status, $B/ci-log, $B/ci-runs
Defaults!$B/cicd-ingest,$B/ci-status,$B/ci-log,$B/ci-runs !requiretty
EOF
chmod 440 /etc/sudoers.d/cicd-runner
visudo -cf /etc/sudoers.d/cicd-runner

# ---- seed 'app' with a CI manifest so `git archive` + run-group have a job to run -----
sudo -u git -H bash -lc '
  set -eu; cd "$HOME"
  # local push to app.git: the gitolite update hook needs the env that gitolite-shell would
  # set over ssh - GL_LIBDIR/GL_BINDIR (perl libs) + GL_REPO/GL_USER (authz). With these the
  # push passes the hook AND the real post-receive (cicd) fires, like a true push.
  # (No apostrophes in these comments - this whole block is single-quoted in the sudo call.)
  export GL_LIBDIR="$(gitolite query-rc GL_LIBDIR)" GL_BINDIR="$(gitolite query-rc GL_BINDIR)" GL_REPO=app GL_USER=alice
  rm -rf appwork; git clone "$HOME/repositories/app.git" appwork
  mkdir -p appwork/.gitolite
  printf "version: 1\njobs:\n  build:\n    on: { push: { branches: [master] } }\n    image: alpine\n    run: echo building\n" > appwork/.gitolite/ci.yml
  git -C appwork add -A
  git -C appwork -c user.email=t@t -c user.name=t commit -m init
  git -C appwork push origin HEAD:master
'
echo "PROVISION OK: $(sudo -u git -H gitolite list-phy-repos | tr "\n" " ")"
