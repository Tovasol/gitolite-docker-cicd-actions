# CI/CD Runner — Standard Operating Procedures

> Copy-paste runbook for the hand-rolled gitolite + docker CI/CD runner.
> This is the **what to do**; rationale lives in `CI-RUNNER-DESIGN.md` (§ refs).
> Decisions locked: **ramfs** for the in-RAM key (never swaps), **age** for the
> unattended runner key, **GPG/pass** for humans, **rootless docker**.

Last updated: 2026-06-22

---

## 0. Quick reference (the thing you'll forget)

**Health check anytime:**
```bash
ssh vps && sudo -iu cicd-runner ci-status     # key loaded? docker up? recent runs?
```

**Simple key path (default, §2.3):** the age key persists on disk — **nothing to do
after a reboot** except make sure rootless dockerd is back up (it's a service). If a
deploy "silently didn't happen", run `ci-status` and check `runner.log`.

**ramfs key path — after EVERY reboot, re-post the key (CI is paused until you do).**
From your **Mac** (key streams Mac→VPS RAM; never on disk, never in history):
```bash
pass show <your-key-entry> | ssh <user>@vps 'sudo -n -u cicd-runner /home/cicd-runner/runner/bin/unlock-ci'
```
Then confirm: `sudo -iu cicd-runner ci-status` → `age key loaded`.
(GPG-at-rest variant instead: `sudo -iu cicd-runner unlock-ci` decrypts the on-VPS
`age-key.gpg`, prompting for the GPG passphrase. Use whichever you set up.)

---

## 0.5 Wiring quickstart (zero → first deploy)

Staged so each layer is verifiable. Detail in §2. Prereq: rootless docker running
as `cicd-runner` (`docker info` shows rootless).

```bash
# ── A. install the runner — bootstrap from the bare repo (as ROOT; install is root's job) ──
# archive the runner code out of gitolite into cicd-runner (archive-push principle, by hand).
# Code's already there from the push that made the bare repo. NOT the runtime grant.
GIT_HOME=$(getent passwd git | cut -d: -f6)          # /var/lib/gitolite or /home/git
RUNNER_REPO=$GIT_HOME/repositories/<runner-repo>.git
sudo -u cicd-runner mkdir -p /home/cicd-runner/src
git --git-dir="$RUNNER_REPO" archive main cicd-runner | sudo -u cicd-runner tar -x --strip-components=1 -C /home/cicd-runner/src
sudo -iu cicd-runner bash -lc 'cd ~/src && ./install.sh'

# ── B. point config at your socket (as cicd-runner; user-local, no sudo) ──────
echo "$DOCKER_HOST"                       # the value that makes `docker info` work
vi ~/runner/etc/runner.conf               # DOCKER_HOST=<that>  RESOURCE_LIMITS=0  NOTIFY_CMD=""
                                          # SOPS_AGE_KEY_FILE=/run/ci-keys/age-keys.txt  (ramfs)

# ── C. hook + sudo bridge (as root) ──────────────────────────────────────────
# LOCAL_CODE is already set in most gitolite installs — ask gitolite where it resolves
# (don't assume ~git/local; some installs use $GL_ADMIN_BASE/local).
LOCAL_CODE=$(sudo -u git gitolite query-rc LOCAL_CODE)        # e.g. /var/lib/gitolite/.gitolite/local
install -Dm755 /home/cicd-runner/runner/bin/post-receive "$LOCAL_CODE/hooks/common/post-receive"
chown -R git:git "$LOCAL_CODE"
# (if LOCAL_CODE printed empty, add to %RC in $(getent passwd git|cut -d: -f6)/.gitolite.rc:
#    LOCAL_CODE => "$ENV{HOME}/local",   then re-run query-rc)
cat > /etc/sudoers.d/cicd-runner <<'EOF'
git ALL=(cicd-runner) NOPASSWD: /home/cicd-runner/runner/bin/cicd-ingest
Defaults!/home/cicd-runner/runner/bin/cicd-ingest !requiretty
EOF
chmod 440 /etc/sudoers.d/cicd-runner && visudo -cf /etc/sudoers.d/cicd-runner
sudo -iu git gitolite setup --hooks-only

# ── D. smoke test (NO secrets) — in your repo on your Mac ─────────────────────
mkdir -p .gitolite ci
printf 'version: 1\njobs:\n  smoke:\n    on: { push: { branches: [main] } }\n    image: alpine\n    run: sh ci/smoke.sh\n' > .gitolite/ci.yml
printf '#!/usr/bin/env sh\n. /cicd/lib.sh\nstep smoke\necho "CI works: $CI_REPO $CI_BRANCH $CI_SHA"\nnotify_success "smoke ok"\n' > ci/smoke.sh
git add .gitolite ci && git commit -m 'ci: smoke' && git push origin main
#   watch on VPS:  tail -f /home/cicd-runner/runner/runner.log
#                  cat /home/cicd-runner/runner/runs/<repo>/main/latest/output.log   # "CI works: …"

# ── E. real deploy (after smoke passes) ──────────────────────────────────────
#   1) ramfs key + `unlock-ci` (§2.3/§3)   2) .sops.yaml + `sops ci/secrets.enc.yaml`
#   3) swap smoke for examples/.gitolite/ci.yml + examples/ci/deploy-site.sh
#   4) NOTIFY_CMD=…/bin/notify-email   5) push -> watch
```
First-timer gotchas: **`DOCKER_HOST` mismatch** (every job fails instantly) and
**secret jobs need `unlock-ci`** first (clear "key not loaded" error otherwise).

---

## 1. Conventions — where everything lives

> **Authoritative source:** the scripts + paths live in the repo `cicd-runner/`
> and are laid down by `cicd-runner/install.sh` (which reads `runner.conf`).
> User = **`cicd-runner`**, base = **`/home/cicd-runner/runner`**.

| Thing | Path |
|---|---|
| Runner user | `cicd-runner` (home `/home/cicd-runner`) |
| Runner base | `/home/cicd-runner/runner/` (= `$RUNNER_BASE`) |
| Job queue | `$RUNNER_BASE/queue/<repo>/<branch>/` |
| Run logs/history | `$RUNNER_BASE/runs/<repo>/<branch>/<ts>-<sha>-<job>/` |
| Global dep cache (§32) | `$RUNNER_BASE/cache/` (one volume, all repos, all ecosystems) |
| Ephemeral env state | `$RUNNER_BASE/envs/<repo>/<slug>/` |
| Runner age key (simple, default) | `~cicd-runner/.config/sops/age/keys.txt` (600, no root) |
| Runner key encrypted-at-rest (optional §25) | `$RUNNER_BASE/etc/age-key.gpg` (cicd-runner-owned, no root) |
| Decrypted key in RAM (optional §25) | `/run/ci-keys/age-keys.txt` (ramfs, created+mounted by the boot service start_pre) |
| Config | `$RUNNER_BASE/etc/runner.conf` (user-local; found via $CICD_BASE, sudo-safe). `/etc/cicd-runner/runner.conf` optional fallback only. Hook does NOT read it. |
| Per-repo secrets (in git) | `<repo>/ci/secrets.enc.yaml` |
| sops recipients config (in git) | `<repo>/.sops.yaml` |
| Hook (gitolite) | `$LOCAL_CODE/hooks/common/post-receive` (find via `gitolite query-rc LOCAL_CODE`) |
| Runner scripts | `$RUNNER_BASE/bin/` (`run-group.sh`, `unlock-ci`, `ci-status`, reapers…) |

Key fact: **decrypt happens on the host; only decrypted VALUES enter the
container.** The age key never enters a build container.

---

## 2. Provision a new runner host (server move / first setup)

Do this once per VPS. Order matters.

### 2.1 Tools — user-local, NOT system-wide
The CI tools (sops, yq, age) install into `~cicd-runner/.local/bin` — no root, no
`/usr/local`. `install.sh` (§2.4) runs `fetch-tools.sh` for you; or do it directly:
```bash
su - cicd-runner
mkdir -p ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bash_profile && . ~/.bash_profile
~/src/bin/fetch-tools.sh        # downloads sops, yq, age into ~/.local/bin (arch-aware)
sops --version && yq --version && age-keygen --version
```
The runner re-prepends `~/.local/bin` to PATH itself (config `LOCAL_BIN`) so it's
found even under `sudo` (which resets PATH).

The only **system** deps (genuine runtime, reasonably shared): **docker** (rootless,
§2.2), **flock** (`sys-apps/util-linux`, usually already installed), and — only for
the optional encrypted-at-rest key (§2.5) — **gpg** (`app-crypt/gnupg`). sops/yq/age
are never system-wide.

### 2.2 Runner user + rootless docker
```bash
useradd -m -s /bin/bash cicd-runner
```
Then set up rootless docker — **see Appendix A** for the full verified Gentoo
procedure (packages, subuid/subgid, kernel `CONFIG_USER_NS`, and the systemd-vs-
OpenRC autostart fork). Do NOT just `loginctl enable-linger` — that's the systemd
path and fails on pure OpenRC. Verify at the end:
```bash
sudo -iu cicd-runner bash -lc 'docker info | grep -i rootless'   # → "rootless"
```
> **Note:** Appendix A writes the runner user as `ci` purely for line-width — it's
> a placeholder. The real user is **`cicd-runner`**; read every `ci`/`/home/ci/`/
> `id -u ci` there as `cicd-runner`/`/home/cicd-runner/`/`id -u cicd-runner`.

### 2.3 Runner age key (simple path — default, no root)
A passphraseless age key sops finds automatically. Protected by file perms + the
host (the runner user owns it). This is what you set up first.
```bash
su - cicd-runner
mkdir -p ~/.config/sops/age && chmod 700 ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt && chmod 600 ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt        # record age1RUNNER… (a .sops.yaml recipient)
vi ~/runner/etc/runner.conf
#   SOPS_AGE_KEY_FILE=/home/cicd-runner/.config/sops/age/keys.txt
```
No backup needed: if the VPS dies, regen + re-add the pubkey to `.sops.yaml` +
`sops updatekeys`; your human key (the 2nd recipient) keeps you from lockout.

### 2.4 Runner directories + scripts (via install.sh)
The runner code is already in gitolite (your push created the bare repo). Bootstrap
by archiving it out of the bare repo into cicd-runner — the **same archive-push
principle** the system uses, run once by hand. No rsync, no Mac round-trip, no repo
access grant for cicd-runner.
```bash
# (a) PRIMARY — as ROOT (install ops are root's job; a separated admin can't reach
#   git's dirs — good). root reads the bare repo, cicd-runner writes. This is an
#   INSTALL-time op, NOT the runtime git→cicd-runner grant (which stays cicd-ingest-only).
GIT_HOME=$(getent passwd git | cut -d: -f6)          # /var/lib/gitolite or /home/git — varies
RUNNER_REPO=$GIT_HOME/repositories/<runner-repo>.git
sudo -u cicd-runner mkdir -p /home/cicd-runner/src
# use the real default branch (gitolite's HEAD may be 'master' while you pushed 'main'):
git --git-dir="$RUNNER_REPO" archive main cicd-runner \
  | sudo -u cicd-runner tar -x --strip-components=1 -C /home/cicd-runner/src
#   (own repo, not a cicd-runner/ subdir? drop the path + --strip-components)
sudo -iu cicd-runner bash -lc 'cd ~/src && ./install.sh'
# update later: re-run the pipe (latest HEAD) + ./install.sh — or dogfood it via CI.

# (b) FALLBACK — only if the code isn't in gitolite yet: rsync from your Mac
#   rsync -av ~/…/agent-forge/cicd-runner/ you@vps:/tmp/cicd-runner/
#   sudo -iu cicd-runner bash -lc 'cp -r /tmp/cicd-runner ~/src && cd ~/src && ./install.sh'
```
`install.sh` fetches yq/sops/age into `~/.local/bin`, lays down all dirs (incl.
`incoming/` + the global `cache/`), seeds slots, writes `runner.conf`. Then review it:
```bash
sudo -iu cicd-runner vi ~/runner/etc/runner.conf
#   DOCKER_HOST=<your working socket>   RESOURCE_LIMITS=0   NOTIFY_CMD=""
#   SOPS_AGE_KEY_FILE=/run/ci-keys/age-keys.txt    ← you're using ramfs
```
`install.sh` creates `queue/ runs/ cache/ envs/ slots/ bin/`, copies all scripts,
seeds the concurrency slot files (`MAX_JOBS`), fills `DOCKER_HOST` with the user's
UID, and runs a dependency preflight (yq/sops/age/docker/flock).

### 2.5 (Optional, §25) Harden the key: encrypt at rest + ramfs
Only if you want the key encrypted at rest + human-gated boot. Skip for first run.
The encrypted key lives in the runner dir (cicd-runner-owned — no /etc, no root for
the file). Only the ramfs *mount* needs root.
```bash
# as cicd-runner: GPG-encrypt the key to your GPG (move it out of plaintext keys.txt)
su - cicd-runner
age-keygen -y ~/.config/sops/age/keys.txt    # note pubkey (recipient)
gpg --encrypt --recipient YOUR_GPG_FP --armor \
  -o ~/runner/etc/age-key.gpg < ~/.config/sops/age/keys.txt
shred -u ~/.config/sops/age/keys.txt          # remove the plaintext on-disk copy

# as root: ramfs for the decrypted key (never swaps). NOT via fstab — /run is tmpfs
# (wiped each boot) so the mountpoint won't persist + an fstab entry fails at boot.
# The boot SERVICE's start_pre creates+mounts+chowns it (Appendix A "Reboot survival").
# For a one-off now:
mkdir -p /run/ci-keys && mount -t ramfs ramfs /run/ci-keys
chown cicd-runner:cicd-runner /run/ci-keys && chmod 700 /run/ci-keys

# point the runner at the ramfs path:
#   runner.conf: SOPS_AGE_KEY_FILE=/run/ci-keys/age-keys.txt
```
No-root alternative to ramfs (if the box has **no swap**): use a `700` subdir of
`/dev/shm` (tmpfs, already mounted) instead — no fstab, no root. ramfs is only
needed to guarantee no-swap when swap is on.

### 2.6 gitolite hook + the sudo bridge (git → cicd-runner)
The hook runs as **git**; the runner + rootless docker run as **cicd-runner**
(separate trust domains — DESIGN §30/§31). The hook `git archive`s the tree and pipes
it via `sudo -n -u cicd-runner cicd-ingest …` (archive-push). Set up the grant:

```bash
# 1) install the hook where gitolite's LOCAL_CODE resolves (don't assume the path)
LOCAL_CODE=$(sudo -u git gitolite query-rc LOCAL_CODE)
install -Dm755 /home/cicd-runner/runner/bin/post-receive "$LOCAL_CODE/hooks/common/post-receive"
chown -R git:git "$LOCAL_CODE"
sudo -iu git gitolite setup --hooks-only

# 2) the sudo bridge — git may run ONLY cicd-ingest as cicd-runner, no password
cat > /etc/sudoers.d/cicd-runner <<'EOF'
git ALL=(cicd-runner) NOPASSWD: /home/cicd-runner/runner/bin/cicd-ingest
Defaults!/home/cicd-runner/runner/bin/cicd-ingest !requiretty
EOF
chmod 440 /etc/sudoers.d/cicd-runner
visudo -cf /etc/sudoers.d/cicd-runner          # validate
```
Notes:
- **No chmod needed on cicd-runner's home.** `sudo -u cicd-runner cicd-ingest`
  execs AS cicd-runner, who owns and can traverse its own 700 home; sudo's pre-exec
  stat runs as root (bypasses perms). git never reads/traverses the path itself.
- `!requiretty` is required — the hook runs with no tty; without it `sudo -n` fails.
- The hook needs no read access to the runner (sudo executes cicd-ingest AS
  cicd-runner). It only needs the *path string* + the sudo grant. It reads no
  secrets and sources no runner files.
- Verify the grant is active (no side effects):
  `sudo -l -U git | grep cicd-ingest`  → prints: (cicd-runner) NOPASSWD: …/cicd-ingest
  Then any push exercises it for real (watch `tail -f ~cicd-runner/runner/runner.log`).

### 2.7 Maintenance crons (§9)
Install the reaper + prune + orphaned-env crons. See §9.

### 2.8 First unlock
```bash
unlock-ci && ci-status
```

> **Server move checklist:** repeat 2.1–2.8 on the new box. Because each host has
> its OWN runner key, generate a fresh one (2.5) and enroll it; do NOT copy the
> old host's key. Decommission the old host by removing its `age1vps...` line from
> every `.sops.yaml` + `sops updatekeys` + rotate secrets (§6 revoke).

---

## 3. After reboot — re-post the ramfs key

The ramfs key is wiped on reboot (RAM-only, by design — §25). Everything else comes
back automatically (docker service, ramfs mount + chown via `/etc/local.d`,
`@reboot ci-recover`). You re-supply the key.

> **Pushes during the reboot window are NOT lost.** A push that lands before you
> re-post the key is *deferred* (parked, not failed): docker-down or key-not-loaded
> secret jobs leave their queue target pending. When you run `unlock-ci` below it
> **auto-triggers `ci-recover`** and the deferred pushes run immediately — you don't
> re-push. A `*/10 ci-recover` cron is the backstop if the key is posted out-of-band.
> (Deferred-recovery, DESIGN §10.6/§33.)

**Key-in-pass (your setup) — from the Mac, one line (key never on disk/history):**
```bash
pass show <your-key-entry> | ssh <user>@vps 'sudo -n -u cicd-runner /home/cicd-runner/runner/bin/unlock-ci'
# → "runner key loaded into /run/ci-keys/age-keys.txt (pub: age1…) — clears on reboot"
sudo -iu cicd-runner ci-status     # confirm: age key loaded
```
`unlock-ci` reads the key on **stdin** (the piped value), validates it's a real age
key, writes `600` into the ramfs file. No `-t` on the ssh (a tty breaks the pipe).

**GPG-at-rest variant** (if you chose §2.5 instead): `sudo -iu cicd-runner unlock-ci`
with no stdin → decrypts `$RUNNER_BASE/etc/age-key.gpg` (prompts GPG passphrase).

If `/run/ci-keys` is empty after reboot that's expected (ramfs wipes) — just re-post.
If the mount itself is gone: `sudo mount /run/ci-keys` (then the `/etc/local.d` chown,
or `sudo chown cicd-runner:cicd-runner /run/ci-keys`).

---

## 4. Onboard a new project to CI

In the project repo, on your Mac:

### 4.1 Add the pipeline logic (durable, vendor-neutral)
```bash
mkdir -p ci
cat > ci/deploy-site.sh <<'EOF'
#!/usr/bin/env sh
set -eu
cd site/scaffold
npm ci
npm run build
npx wrangler pages deploy dist --project-name=<project>-site
EOF
```

### 4.2 Add the trigger manifest
```bash
mkdir -p .gitolite
cat > .gitolite/ci.yml <<'EOF'
version: 1
jobs:
  deploy-site:
    on: { branches: [main], paths: ["site/**"] }
    image: node:20-alpine
    secrets: [cloudflare]
    run: sh ci/deploy-site.sh
EOF
```

### 4.3 Add secrets (encrypted) — see §5

### 4.4 Commit + push
```bash
git add ci .gitolite .sops.yaml ci/secrets.enc.yaml
git commit -m "ci: enroll project"
git push        # first push won't run if hook predates it; subsequent pushes do
```

---

## 5. Add or rotate a secret value

On your Mac (you must be a recipient in `.sops.yaml`):
```bash
# .sops.yaml at repo root (once per repo) — humans via pgp, runner via age:
cat > .sops.yaml <<'EOF'
creation_rules:
  - path_regex: \.enc\.(ya?ml|json|env)$
    pgp: "YOUR_GPG_FINGERPRINT"
    age: "age1vps_runner_pubkey"
EOF

sops ci/secrets.enc.yaml      # opens editor; add/edit values; encrypts on save
# values: cloudflare_api_token, npm_token, etc.
git add ci/secrets.enc.yaml && git commit -m "ci: update secrets" && git push
```
**Rotating a leaked token:** change the value in `sops`, push, AND invalidate the
old token at the provider (e.g. revoke the Cloudflare token in the dashboard).

The runner reads these at run time via the §1 host key — no action needed there.

---

## 6. Manage access (add / remove a device or person)

### Add a recipient (new laptop, phone, teammate, new server key)
```bash
# 1. get the new public key:
#    age:  age-keygen -y keys.txt   |   pgp:  gpg --fingerprint
# 2. add it to .sops.yaml (pgp: or age:)
# 3. re-encrypt the data key on EVERY secrets file:
find . -name '*.enc.*' -print0 | xargs -0 -I{} sops updatekeys -y {}
git commit -am "ci: add recipient <who>" && git push
```

### Remove / revoke a recipient
```bash
# 1. delete its line from .sops.yaml
# 2. sops updatekeys on all files (as above)
# 3. ROTATE the actual secret values (§5) — they already saw them
git commit -am "ci: revoke <who>" && git push
```
Rule: keep **≥2 recipients** always (you + the runner) so you can't lock yourself
out.

---

## 7. Rotate the runner's age key

```bash
# on the VPS, as cicd-runner (simple path):
su - cicd-runner
age-keygen -o ~/.config/sops/age/keys.txt && chmod 600 ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt      # record the NEW age1RUNNER… pubkey
#   (hardened path instead: gpg-encrypt to ~/runner/etc/age-key.gpg + unlock-ci)
# on Mac: replace old age1RUNNER… with the new one in every .sops.yaml, then:
find . -name '*.enc.*' -print0 | xargs -0 -I{} sops updatekeys -y {}
git commit -am "ci: rotate runner key" && git push
```

---

## 8. Operate / debug a CI run

```bash
# latest run for a repo/branch:
ls -t /home/cicd-runner/runner/runs/<repo>/<branch>/ | head
cd /home/cicd-runner/runner/runs/<repo>/<branch>/<ts>-<sha>/
cat status           # running | exit:<n> | timeout | cancelled
cat output.log       # full stdout+stderr
cat cmd              # exact docker run — paste to reproduce the failed container by hand
cat meta.json        # who pushed, branch, sha, timings

# follow a live run:
tail -f /home/cicd-runner/runner/runs/<repo>/<branch>/latest/output.log

# re-trigger: just RE-PUSH from your Mac — the hook re-archives + re-delivers the
# source (archive-push). The runner has no repo access, so it can't reconstruct the
# tree on its own; a re-push is the clean way. (git push --force-with-lease or an
# empty commit both work.) For a FAILED teardown: `ci-teardown retry <repo> <branch>`.
```
First debugging question is always: **is the key loaded?** `ci-status`. A missing
key after reboot is the #1 cause of "nothing happened."

---

## 9. Routine maintenance (crons — set once, verify occasionally)

Install the bundled crontab (as `cicd-runner`):
```bash
crontab /home/cicd-runner/src/crontab.sample
crontab -l        # verify
```
It wires the named scripts (each sources `runner.conf`):
- `*/10 * * * * reap-containers` — kill leaked/dead/runaway containers, free slots
- `0 4 * * * prune-disk` — docker prune (capped) + run-log retention + disk guard
- `0 5 * * * reap-envs` — tear down ephemeral envs whose branch is gone (§14)
- `@reboot ci-recover` — re-run targets never processed (secret-using jobs *defer*,
  not fail, until `unlock-ci` — which then auto-drains them)
- `*/10 * * * * ci-recover` — deferred-recovery backstop: re-runs anything parked
  because the env wasn't ready (docker late / key out-of-band). No-op when idle.

Verify quarterly: `docker system df`, `df -h $(docker info -f '{{.DockerRootDir}}')`,
`crontab -l`.

---

## 10. Incident playbooks

### "Deploy didn't run / nothing happened"
1. `ci-status` — key loaded? If not → `unlock-ci` (reboot wiped ramfs). #1 cause.
2. Did the push touch the manifest's `paths:`? Path filter may have skipped it.
3. `ls -t runs/<repo>/<branch>/` — any run dir? Read `status` + `output.log`.
4. Hook firing? Check `queue/<repo>/<branch>/target` updated on push.

### "Disk full — all jobs failing"
```bash
docker system df; df -h /var/lib/docker
docker builder prune --keep-storage 5g -f; docker image prune -af --filter until=24h
find /home/cicd-runner/runner/runs -mtime +14 -type d -exec rm -rf {} +    # trim logs
```
Never `docker system prune -a` casually — nukes the layer cache, slows all builds.

### "Stuck / hung job"
```bash
docker ps --filter label=cicd=1                 # find it
docker rm -f <name>                            # kill; runner marks status + frees slot
```
Wall-clock timeout (§8 design) should catch these automatically; this is the
manual override.

### "Secret leaked"
1. Revoke the token at the provider immediately (Cloudflare/npm dashboard).
2. `sops` a new value + push (§5).
3. If a recipient key leaked: revoke it (§6) + rotate ALL values it could read.

### "Lost access / locked out"
Decrypt from any other recipient (your Mac via GPG). If the ONLY recipient was a
dead host → secrets are unrecoverable; re-create them. (This is why §6 says keep
≥2 recipients.)

---

## Appendix A — Provision the rootless docker user on Gentoo
> In this appendix `ci` is a **placeholder for `cicd-runner`** (kept short for
> readability). Read every `ci` / `ci:ci` / `id -u ci` as `cicd-runner`.

Verified against current Gentoo sources (2026). Replaces the placeholder in §2.2.
Substitute `ci` = runner user; find its UID with `id -u ci` (paths below assume
`/run/user/<UID>`).

**Corrected facts (don't trip on these):**
- Atoms: `app-containers/docker`, `app-containers/docker-cli`,
  `app-containers/slirp4netns`, `sys-apps/rootlesskit`. **No `rootless` USE flag.**
- `CONFIG_USER_NS=y` is NOT default in gentoo-sources — verify + rebuild kernel.
- `kernel.unprivileged_userns_clone` is Debian-only — ignore.
- `newuidmap`/`newgidmap` ship setuid in modern `sys-apps/shadow` — verify only.
- Which init? `ps -p 1 -o comm=` → systemd vs OpenRC (changes step 6).

**KEY CAVEAT (interacts with design §7):** under rootless on OpenRC,
`--memory`/`--pids-limit` are SILENTLY IGNORED unless cgroup v2 delegation is set
up (block at the end). On systemd it's automatic. Without it, rely on the other
§7 hardening.

### Common steps (as root)
```bash
# 1. Kernel
grep CONFIG_USER_NS /usr/src/linux/.config        # must be =y (enable + rebuild if not)
echo -e "tun\noverlay" > /etc/modules-load.d/docker.conf && modprobe tun overlay

# 2. Packages
emerge --ask app-containers/docker app-containers/docker-cli \
  app-containers/slirp4netns sys-apps/rootlesskit
ls -l /usr/bin/newuidmap                          # expect -rwsr-xr-x

# 3. subuid/subgid
usermod --add-subuids 100000-165535 --add-subgids 100000-165535 ci

# 4. sysctl
printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/90-rootless-docker.conf && sysctl --system
```

> **Rootful + rootless side by side is supported** — separate daemons, sockets,
> storage, network. Disabling the system docker (the `rm -f /var/run/docker.sock`
> + `systemctl disable`/`rc-update del docker` in the variants below) is OPTIONAL
> — do it only for a dedicated rootless-only box. If you keep rootful for other
> workloads, leave it running.
>
> **CRITICAL SECURITY RULE when both run:** the `ci` user must reach ONLY the
> rootless socket. **Never add `ci` to the `docker` group** (= access to the root
> daemon's socket = root-equivalent, defeats rootless). Keep `ci`'s `DOCKER_HOST`
> on `/run/user/<uid>/docker.sock`. Toggle which daemon the CLI targets with
> `docker context use rootless` / `docker context use default`. Run §9 prune
> crons against BOTH contexts (each has its own image store).

### Variant A — systemd
```bash
# root:
systemctl disable --now docker.service docker.socket 2>/dev/null
loginctl enable-linger ci
# as ci:
sudo -iu ci bash -lc '
  dockerd-rootless-setuptool.sh install
  systemctl --user enable --now docker
  echo "export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock" >> ~/.bash_profile
'
```

### Variant B — OpenRC (system-level supervise-daemon dropping to `ci`; most robust)
```bash
# root:
rc-update del docker default 2>/dev/null; rc-service docker stop 2>/dev/null
UID_CI=$(id -u ci)

# pre-create /run/user/<uid> at boot
cat > /etc/local.d/00-ci-runtime.start <<EOF
#!/bin/sh
install -d -m 0700 -o ci -g ci /run/user/${UID_CI}
EOF
chmod +x /etc/local.d/00-ci-runtime.start && /etc/local.d/00-ci-runtime.start

# system service that runs rootless dockerd as ci
cat > /etc/init.d/docker-rootless-ci <<EOF
#!/sbin/openrc-run
name=\$RC_SVCNAME
description="Rootless Docker for ci"
supervisor="supervise-daemon"
command="/usr/bin/dockerd-rootless.sh"
command_user="ci"
supervise_daemon_args=" -e PATH=/usr/bin:/usr/sbin:/bin:/sbin -e HOME=/home/ci -e XDG_RUNTIME_DIR=/run/user/${UID_CI}"
depend() { need net localmount; }
EOF
chmod +x /etc/init.d/docker-rootless-ci

# initialize once as ci, then enable at boot
sudo -iu ci bash -lc "export XDG_RUNTIME_DIR=/run/user/${UID_CI}; dockerd-rootless-setuptool.sh install"
sudo -iu ci bash -lc '
  echo "export XDG_RUNTIME_DIR=/run/user/$(id -u)" >> ~/.bash_profile
  echo "export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock" >> ~/.bash_profile
'
rc-update add docker-rootless-ci default && rc-service docker-rootless-ci start
```
(elogind alternative: `emerge sys-auth/elogind`, `rc-update add elogind boot`, then
a per-user OpenRC 0.60 user service — but the system-level service above needs no
elogind and no user session.)

### Reboot survival — the production boot service (§33)
Use the **version-controlled init script** (`cicd-runner/init/docker-rootless-cicd-runner.openrc`)
instead of the hand-rolled Variant B above — it adds the ramfs key-dir bring-up to
`start_pre` (verify-mounted-as-ramfs + chown) and computes the uid, so docker AND the
key dir come back together on every boot.

**Do NOT put `/run/ci-keys` in `/etc/fstab`.** `/run` is tmpfs (wiped each boot), so
the mountpoint dir doesn't persist → an fstab mount fails at boot (no mountpoint) and
can break `localmount` (which docker `need`s → cascade). `start_pre` owns the ramfs
bring-up instead: (re)create the dir → mount ramfs → chown.
```bash
# 1) (if you added it earlier) remove the broken fstab line
sed -i '\#/run/ci-keys#d' /etc/fstab

# 2) install the shipped init script + enable at boot
install -m755 /home/cicd-runner/src/init/docker-rootless-cicd-runner.openrc \
  /etc/init.d/docker-rootless-cicd-runner
rc-update add docker-rootless-cicd-runner default

# 3) stop any manual `setsid dockerd-rootless` first, then start the service
sudo -iu cicd-runner pkill -f dockerd-rootless 2>/dev/null; sleep 2
rc-service docker-rootless-cicd-runner start
```
`start_pre` does (DESIGN §33 — self-contained, no fstab):
```sh
checkpath -d -m 0755 -o root:root /run/user
checkpath -d -m 0700 -o cicd-runner:cicd-runner /run/user/$(id -u cicd-runner)
checkpath -d -m 0700 /run/ci-keys                    # mountpoint (wiped each boot)
mountpoint -q /run/ci-keys || mount -t ramfs ramfs /run/ci-keys
chown cicd-runner:cicd-runner /run/ci-keys && chmod 700 /run/ci-keys
```
- The mountpoint **must be created in `start_pre`** (it's on tmpfs `/run`, gone each
  boot) — *then* the ramfs is mounted over it. No fstab involved.
- `/etc/local.d/00-ci-keys.start` is **redundant** — `rm` it (or leave it; idempotent).
- **Verify after start** (and after a real reboot):
  ```bash
  rc-service docker-rootless-cicd-runner status        # started
  findmnt /run/ci-keys                                 # FSTYPE must be ramfs (NOT tmpfs)
  sudo -iu cicd-runner sh -c 'docker info 2>/dev/null | grep -i rootless'
  ```
- The key itself does NOT auto-restore (RAM-only, §25) — re-post it after reboot (§3).

### elogind activation (only if you chose the elogind route, not Variant B)
`XDG_RUNTIME_DIR` is set by `pam_elogind.so` at session-open, which also creates
`/run/user/<uid>`. Requires ALL three: elogind running + `pam_elogind` in the PAM
stack + a FRESH login. The current shell never gets it retroactively.

**Silent gotcha:** `pam_elogind` is only wired in if `sys-libs/pambase` was built
with the `elogind` USE flag. If you emerged elogind AFTER pambase, the session
line is missing → `XDG_RUNTIME_DIR` never sets, no matter how often you re-login.
```bash
rc-update add dbus default && rc-service dbus start          # elogind needs dbus
grep -rl pam_elogind /etc/pam.d/ || {                        # ensure pambase has it
  echo 'sys-libs/pambase elogind' >> /etc/portage/package.use/elogind
  emerge -1 sys-libs/pambase; }
rc-update add elogind boot && rc-service elogind start
# then LOG OUT + back in (fresh SSH session), or reboot (cleanest on a fresh VPS):
echo $XDG_RUNTIME_DIR        # → /run/user/<uid>;  loginctl  → lists session
```

**For the `ci` service user (never logs in interactively):** a fresh login won't
happen, and `sudo -iu ci` isn't a reliable elogind session. So either:
- `loginctl enable-linger ci` → elogind creates + PERSISTS `/run/user/<uid>` at
  boot without any login (`ls -ld /run/user/$(id -u ci)` to confirm), OR
- **use Variant B**, which pre-creates `/run/user/<uid>` (`/etc/local.d`) and sets
  `XDG_RUNTIME_DIR` in the service args — no elogind needed at all.

Rule of thumb: Variant B = no elogind. elogind route = must `enable-linger ci`.

### Resource limits under rootless OpenRC — NOT possible for Docker
**Docker rootless needs cgroup v2 + systemd to enforce `--memory`/`--pids-limit`.**
On OpenRC (no systemd) docker rootless **cannot** use cgroups — you'll see at
startup: `WARNING: Running in rootless-mode without cgroups`. Expected, NOT fixable.
The chown/delegation block below is a **Podman** capability (crun + cgroupfs); it
does NOT make Docker rootless honor limits. For Docker: set `RESOURCE_LIMITS=0` in
runner.conf so the runner omits those (no-op) flags. All other hardening (cap-drop,
no-new-privileges, network, wall-clock timeout) still applies; host OOM-killer +
timeout are the backstop. See DESIGN §29. Need real per-container caps on OpenRC →
switch the runtime to Podman rootless.

### (Podman only) cgroup v2 delegation — does NOT apply to Docker rootless
```bash
# /etc/rc.conf
rc_cgroup_mode="unified"
# then:
rc-update add cgroups boot && rc-service cgroups start
groupadd cgroup; usermod -aG cgroup ci
cat > /etc/local.d/01-cgroup-deleg.start <<'EOF'
#!/bin/sh
mount --make-rshared /
chown root:cgroup /sys/fs/cgroup /sys/fs/cgroup/cgroup.procs /sys/fs/cgroup/cgroup.subtree_control /sys/fs/cgroup/cgroup.threads
chmod 775 /sys/fs/cgroup; chmod 664 /sys/fs/cgroup/cgroup.procs /sys/fs/cgroup/cgroup.subtree_control /sys/fs/cgroup/cgroup.threads
EOF
chmod +x /etc/local.d/01-cgroup-deleg.start && /etc/local.d/01-cgroup-deleg.start
# (Gentoo flags this as a minor security tradeoff. Skip if you don't need resource limits.)
```

### Verify
```bash
sudo -iu ci bash -lc 'docker info | grep -iE "context|rootless"'   # → rootless
sudo -iu ci bash -lc 'docker run --rm hello-world'
sudo -iu ci bash -lc 'docker info | grep "Docker Root Dir"'        # → /home/ci/.local/share/docker
```
