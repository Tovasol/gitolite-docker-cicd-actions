# CI/CD Runner — Standard Operating Procedures

> Copy-paste runbook for the hand-rolled gitolite + docker CI/CD runner.
> This is the **what to do**; rationale lives in `CI-RUNNER-DESIGN.md` (§ refs).
> Decisions locked: **ramfs** for the in-RAM key (never swaps), **age** for the
> unattended runner key, **GPG/pass** for humans, **rootless docker**.

Last updated: 2026-06-22

---

## 0. Quick reference (the thing you'll forget)

**After EVERY reboot of the VPS, CI is dead until you run this:**
```bash
ssh ci-vps
unlock-ci            # prompts for GPG passphrase, loads age key into ramfs
ci-status            # verify: key loaded + a test decrypt works
```
If a deploy "silently didn't happen," first check: did the box reboot? → run
`unlock-ci`. See §3.

---

## 1. Conventions — where everything lives

| Thing | Path |
|---|---|
| Runner user | `ci` (home `/home/ci`) |
| Runner base | `/home/ci/ci/` |
| Job queue | `/home/ci/ci/queue/<repo>/<branch>/` |
| Run logs/history | `/home/ci/ci/runs/<repo>/<branch>/<ts>-<sha>/` |
| Per-repo dep cache | `/home/ci/ci/cache/<repo>/` |
| Ephemeral env state | `/home/ci/ci/envs/<repo>/<slug>/` |
| **Encrypted runner key (at rest)** | `/etc/ci/age-key.gpg` |
| **Decrypted runner key (RAM only)** | `/run/ci-keys/age-keys.txt` (ramfs) |
| Per-repo secrets (in git) | `<repo>/ci/secrets.enc.yaml` |
| sops recipients config (in git) | `<repo>/.sops.yaml` |
| Hook (gitolite) | `~git/local/hooks/common/post-receive` |
| Runner scripts | `/home/ci/ci/bin/` (`run-group.sh`, `unlock-ci`, `ci-status`) |

Key fact: **decrypt happens on the host; only decrypted VALUES enter the
container.** The age key never enters a build container.

---

## 2. Provision a new runner host (server move / first setup)

Do this once per VPS. Order matters.

### 2.1 Packages (Gentoo, as root)
```bash
emerge --ask app-crypt/age app-crypt/gnupg
# sops: pin static binary (not in main tree)
curl -LO https://github.com/getsops/sops/releases/download/v3.13.1/sops-v3.13.1.linux.amd64
install -m755 sops-v3.13.1.linux.amd64 /usr/local/bin/sops
sops --version && age --version
```

### 2.2 Runner user + rootless docker
```bash
useradd -m -s /bin/bash ci
```
Then set up rootless docker — **see Appendix A** for the full verified Gentoo
procedure (packages, subuid/subgid, kernel `CONFIG_USER_NS`, and the systemd-vs-
OpenRC autostart fork). Do NOT just `loginctl enable-linger` — that's the systemd
path and fails on pure OpenRC. Verify at the end:
```bash
sudo -iu ci bash -lc 'docker info | grep -i rootless'   # → "rootless"
```

### 2.3 ramfs key mount (never swaps — no swap-killing needed, survives server moves)
```bash
mkdir -p /run/ci-keys
# /etc/fstab — persists the mount config across reboots:
echo 'ramfs  /run/ci-keys  ramfs  nodev,nosuid,mode=0700  0 0' >> /etc/fstab
mount /run/ci-keys
chown ci:ci /run/ci-keys && chmod 700 /run/ci-keys
```

### 2.4 Runner directories + scripts
```bash
sudo -iu ci mkdir -p ~/ci/{queue,runs,cache,envs,secrets,slots,bin}
# copy run-group.sh, unlock-ci, ci-status into ~ci/ci/bin and chmod +x
# create N slot files for the global concurrency cap:
sudo -iu ci bash -c 'for i in $(seq 1 4); do : > ~/ci/slots/$i; done'
```

### 2.5 Generate THIS host's runner age key (see §7 for the encrypt+enroll flow)
```bash
sudo -iu ci age-keygen | sudo -iu ci tee /dev/stderr | \
  gpg --encrypt --recipient YOUR_GPG_FP --armor -o /etc/ci/age-key.gpg
# ^ record the "Public key: age1vps..." printed to stderr
chown ci:ci /etc/ci/age-key.gpg
```
Then add the new `age1vps...` pubkey to each repo's `.sops.yaml` and run
`sops updatekeys` (§6 / §7).

### 2.6 gitolite hook
```bash
# enable LOCAL_CODE in ~git/.gitolite.rc:  LOCAL_CODE => "$ENV{HOME}/local",
# place post-receive in ~git/local/hooks/common/  (guards on $GL_REPO + ci.yml)
chmod +x ~git/local/hooks/common/post-receive
sudo -iu git gitolite setup --hooks-only
```

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

## 3. After every reboot — unlock CI  ⭐ most frequent

```bash
ssh ci-vps
unlock-ci            # enter GPG passphrase when prompted
ci-status            # must show: key loaded, test decrypt OK
```

`unlock-ci` (reference impl):
```bash
#!/usr/bin/env bash
set -euo pipefail
export GPG_TTY=$(tty)
install -d -m700 -o ci -g ci /run/ci-keys
gpg --decrypt /etc/ci/age-key.gpg > /run/ci-keys/age-keys.txt
chown ci:ci /run/ci-keys/age-keys.txt && chmod 600 /run/ci-keys/age-keys.txt
echo "CI key loaded into RAM (ramfs). Clears on reboot."
```
`ci-status` should: confirm `/run/ci-keys/age-keys.txt` exists, and do a throwaway
`sops -d` of any repo's `secrets.enc.yaml` to prove the key works.

If `/run/ci-keys` is empty after reboot → that's expected (ramfs wipes). Just run
`unlock-ci`. If the mount itself is gone → `mount /run/ci-keys` (fstab from 2.3).

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
# on the VPS, as ci:
age-keygen | tee /dev/stderr | gpg --encrypt --recipient YOUR_GPG_FP --armor -o /tmp/age-key.gpg
#   record the new age1... pubkey from stderr
sudo mv /tmp/age-key.gpg /etc/ci/age-key.gpg && sudo chown ci:ci /etc/ci/age-key.gpg
unlock-ci      # load the NEW key into ramfs
# on Mac: replace old age1vps... with new one in every .sops.yaml, then:
find . -name '*.enc.*' -print0 | xargs -0 -I{} sops updatekeys -y {}
git commit -am "ci: rotate runner key" && git push
```

---

## 8. Operate / debug a CI run

```bash
# latest run for a repo/branch:
ls -t /home/ci/ci/runs/<repo>/<branch>/ | head
cd /home/ci/ci/runs/<repo>/<branch>/<ts>-<sha>/
cat status           # running | exit:<n> | timeout | cancelled
cat output.log       # full stdout+stderr
cat cmd              # exact docker run — paste to reproduce the failed container by hand
cat meta.json        # who pushed, branch, sha, timings

# follow a live run:
tail -f /home/ci/ci/runs/<repo>/<branch>/latest/output.log

# manually re-trigger (re-run the last sha): re-push, or:
printf 'push <sha>\n' > /home/ci/ci/queue/<repo>/<branch>/target
/home/ci/ci/bin/run-group.sh <repo>/<branch> <repo> ~git/repositories/<repo>.git <branch>
```
First debugging question is always: **is the key loaded?** `ci-status`. A missing
key after reboot is the #1 cause of "nothing happened."

---

## 9. Routine maintenance (crons — set once, verify occasionally)

```bash
# container reaper (every 10 min): kill leaked/dead containers, free slots
*/10 * * * * docker ps -aq --filter label=ci=1 --filter status=exited --filter status=dead | xargs -r docker rm --volumes

# disk guard + prune (daily): never let /var/lib/docker fill
0 4 * * * docker builder prune --keep-storage 10g --filter until=48h -f; docker image prune -f

# orphaned ephemeral envs (daily): tear down envs whose branch is gone (§14)
0 5 * * * /home/ci/ci/bin/reap-envs.sh

# run-log retention (daily): keep history bounded
0 5 * * * find /home/ci/ci/runs -maxdepth 3 -type d -mtime +30 -exec rm -rf {} +
```
Verify quarterly: `docker system df`, `df -h /var/lib/docker`, crons still listed.

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
find /home/ci/ci/runs -mtime +14 -type d -exec rm -rf {} +    # trim logs
```
Never `docker system prune -a` casually — nukes the layer cache, slows all builds.

### "Stuck / hung job"
```bash
docker ps --filter label=ci=1                 # find it
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

## Appendix A — Provision the rootless docker user (`ci`) on Gentoo

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

# 4. Disable any system docker + sysctl
rm -f /var/run/docker.sock
printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/90-rootless-docker.conf && sysctl --system
```

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

### Optional — cgroup v2 delegation (enables --memory/--pids-limit under rootless OpenRC)
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
