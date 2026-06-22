# Bone-Simple CI/CD Runner — Design Doc

> A no-nonsense, filesystem-transparent CI/CD runner for a single VPS running
> gitolite + docker. Captured from a design discussion. No DAG, no forge, no DB,
> no blackbox. The filesystem is the dashboard.

Status: **design / not yet built**
Last updated: 2026-06-22

> **Operating it?** This doc is the *why*. For copy-paste runbooks (after-reboot
> unlock, onboarding a project, secrets, server moves, incidents) see
> **`CI-RUNNER-SOP.md`**. Locked decisions: ramfs key dir, age for the runner,
> GPG/pass for humans, rootless docker.

---

## 1. Goals & values (the constraints that drove every decision)

- **Trigger:** a `git push` to gitolite; if a project opts in and matching files
  changed, run its build/deploy pipeline.
- **First concrete use case:** on changes under `site/`, run
  `npm run build && npx wrangler pages deploy dist --project-name=pipelineforge-site`
  inside `site/scaffold/` (that's where the Vite app + `wrangler.toml` live).
- **Sandbox:** untrusted `npm`/build commands run inside a throwaway container,
  never on the host.
- **Values (non-negotiable, mirror the gitolite ethos):**
  - Everything on disk, plaintext, greppable. No DB, no opaque app state.
  - Lightweight, readable top-to-bottom (~250 lines bash + cron, like gitolite's perl).
  - **The filesystem IS the dashboard** — `ls` = history, `cat` = logs.
- **Generalizable & migrate-able:** new projects opt in by dropping two files.
  The pipeline *logic* must survive a future move to GitHub Actions / Gitea /
  Forgejo Actions / Woodpecker with zero rewrite.

### Explicitly out of scope
- **DAG / inter-pipeline orchestration** (one pipeline triggering others with
  dependency + failure propagation). Confirmed not needed. This is the one
  feature that does *not* simulate cheaply — if it's ever needed, adopt a real
  engine (Laminar) for that, don't rebuild a scheduler.
- A web UI / clickable dashboard (forces a forge + DB; rejected — see §11).

---

## 2. Why not off-the-shelf (the honest landscape)

Every lightweight, market-norm CI engine is **forge-coupled** — it needs
webhooks + an API + auth from a git host (Gitea/GitHub/GitLab) to get auth + UI
cheaply. Gitolite has none of that (SSH-only, no webhooks, no API). So:

| Option | Verdict |
|---|---|
| Jenkins | rejected — old, heavy, clunky, plugin hell |
| Laminar | closest match to values (filesystem-based, jobs are scripts on disk), but non-norm syntax + sqlite + own web UI; its real value is the DAG we don't need |
| Drone / Woodpecker | forge-coupled — won't run standalone |
| Concourse | standalone + forge-free, but own pipeline syntax + postgres, heavier |
| Tekton | requires Kubernetes — far too heavy for one VPS |
| Gitea/Forgejo + Actions | market-norm (GH-Actions-compatible), but a **binary + DB** → violates "everything on disk" |
| `adnanh/webhook` + docker | transparent HTTP-trigger receiver; only needed for the *multi-host* pattern |

**Key realization:** there is no lightweight + transparent + market-norm +
turnkey standalone CI. That product doesn't exist because the light ones all
chose to couple to a forge. Our actual requirement (transparent on-disk
history/logs for *independent* build→deploy pipelines) is **lighter** than a CI
product, not heavier. So: hand-roll the runner, keep it Actions-shaped for
portability.

**On a single VPS you do not need a webhook at all.** "Project registers webhook
→ CI server clones via SSH" is the multi-host pattern. Here gitolite + docker are
on the same box: push → `post-receive` fires locally → clone is a local path.
The webhook (+ `adnanh/webhook`) only earns its keep if CI ever moves to its own
host. Note also: trigger-auth (HMAC secret) ≠ clone-auth (SSH key) — two
different things.

---

## 3. Architecture — three thin layers

```
git push
  │
  ▼
[gitolite common post-receive hook]   ← fast, no docker. Records newest target sha
  │   writes queue/<group>/target, wakes runner                    + wakes runner
  ▼
[runner]   ← per-group flock + global semaphore; checks triggers; docker run; logs to files
  │
  ▼
[pure container run]   ← build stage (no secrets) + deploy (runtime secrets), throwaway
```

- **Decouple trigger from execution.** Hook does the minimum and returns so the
  push completes instantly. The runner does the slow work detached.
- **Git user must NOT hold the docker socket directly** (docker group =
  root-equivalent). Preferred: hook only writes a job file; a separate runner
  user/service with docker access consumes it. Acceptable shortcut on a
  single-tenant low-risk VPS: hook calls docker inline. Decide per risk tolerance.

---

## 4. The convention (how projects opt in)

Three rules. New project adoption = drop two files + register a secret namespace.
No central code change.

1. **Presence of `.gitolite/ci.yml` = opt-in marker.** No file → runner ignores
   the repo.
2. **Pipeline logic lives in vendor-neutral `ci/*.sh`**, reads secrets from
   **env only** — never hardcoded, never from build args. This script is the
   durable asset that survives any engine migration.
3. **Secrets namespaced per-repo** host-side (`$SECRETS/<repo>/`); the runner
   injects only what the manifest's `secrets:` lists. Build stage gets none.

### `.gitolite/ci.yml` — thin, standard-shaped manifest
Mirrors GitHub Actions `on: {branches, paths}` so migration is mechanical. Keep
it our own minimal schema — do **not** pollute real `docker-compose.yml` with
custom annotations (breaks every compose tool).

```yaml
version: 1
jobs:
  deploy-site:
    on: { branches: [main], paths: ["site/**"] }
    image: node:20-alpine
    secrets: [cloudflare]
    run: sh ci/deploy-site.sh
```

### `ci/deploy-site.sh` — the durable, portable logic
```sh
#!/usr/bin/env sh
set -eu
cd site/scaffold
npm ci
npm run build
npx wrangler pages deploy dist --project-name=pipelineforge-site
# reads CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID from env
```

### Why this migrates cleanly
Same script + same image later under GitHub/Gitea/Forgejo Actions:
```yaml
on: { push: { branches: [main], paths: ["site/**"] } }
jobs:
  deploy-site:
    runs-on: ubuntu-latest
    container: node:20-alpine
    steps:
      - uses: actions/checkout@v4
      - run: sh ci/deploy-site.sh
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
```
You rewrite the ~10-line *trigger manifest*, never the *logic*. That's the
migrate-ability.

---

## 5. Build vs deploy: never inside the Dockerfile

Isolation comes from **the container, not from `docker build`**. `docker run` /
`docker compose run` on a node image is equally sandboxed (same namespaces, same
throwaway via `--rm`). `RUN wrangler deploy` in a Dockerfile is an anti-pattern:

| | `RUN` in Dockerfile | container `command` (`docker run --rm`) |
|---|---|---|
| Sandbox isolation | ✅ | ✅ identical |
| Throwaway | ✅ | ✅ |
| Secrets leak into image layers | ❌ baked into history | ✅ runtime env, never persisted |
| Build/deploy separable | ❌ rebuild = redeploy | ✅ |
| Clean logs + exit code | awkward | ✅ |

`docker build` adds secret-leak + idempotency problems for **zero isolation
gain**. Use a Dockerfile only when a project genuinely *ships an image*; a
Cloudflare Pages static deploy ships nothing, so no Dockerfile needed — just the
throwaway run.

---

## 6. On-disk layout (the dashboard)

```
~/ci/
  queue/<group>/target          # newest requested sha (atomic overwrite)
  queue/<group>/group.lock       # flock target for per-group serialization
  slots/1 .. slots/N             # global concurrency semaphore (flock each)
  secrets/<repo>/<ns>.env        # per-repo secret namespaces, chmod 600
  runs/<group>/<ts>-<sha8>/
      status                     # queued | running | exit:<n> | timeout | cancelled
      meta.json                  # repo, branch, sha, trigger reason, start, end, duration
      cmd                        # exact `docker run …` invocation — reproducible by hand
      output.log                 # combined stdout+stderr
  runs/<group>/latest -> <newest>
```

- **History** → `ls -t ~/ci/runs/<group>/`
- **Logs** → `cat .../output.log`, live `tail -f .../latest/output.log`
- **Debug** → the `cmd` file re-runs the exact failed container by hand;
  `status` has the exit code
- **Group** = `repo[+branch]` (this is "grouping", Laminar-style)

Do NOT rely on `docker logs` (purged with `--rm`). Always redirect to
`output.log` so logs are plain files regardless of container retention.

---

## 7. Concurrency model — group + coalesce

A **concurrency group** = `repo[+branch]`. Within a group, never two runs at
once. This is GitHub Actions `concurrency: { group, cancel-in-progress }` in ~15
lines of bash.

Backlog semantics (what to do when push B lands mid-run of push A):

| Semantic | Behavior | Use when |
|---|---|---|
| Serialize (FIFO) | run every sha in order | need every commit built (tests) |
| **Coalesce** (default) | run A, skip intermediate, jump to newest | efficient, converges to latest |
| Cancel-in-progress | kill A's container, start newest now | **deploys** — only latest matters |

For deploys, deploying sha1→sha2→sha3 is pointless. **Coalesce** (or cancel) is
correct.

### post-receive (fast, non-blocking) — 3-event dispatch
Branch deletion is NOT skipped — it's classified as a `delete` event and
dispatched for teardown (see §14). `target` carries `event sha`.
```sh
#!/usr/bin/env bash
set -euo pipefail
[ "${GL_REPO:-}" ] || exit 0
BARE="$PWD"; Q="$HOME/ci/queue"
ZERO=0000000000000000000000000000000000000000
while read -r oldrev newrev refname; do
  case "$refname" in refs/heads/*) ;; *) continue ;; esac   # branch refs only
  branch="${refname#refs/heads/}"
  if   [ "$oldrev" = "$ZERO" ]; then event=create; sha="$newrev"   # new branch
  elif [ "$newrev" = "$ZERO" ]; then event=delete; sha="$oldrev"   # deleted branch → teardown
  else                                event=push;   sha="$newrev"  # update
  fi
  group="$GL_REPO/$branch"
  mkdir -p "$Q/$group"
  printf '%s %s\n' "$event" "$sha" > "$Q/$group/target.tmp" \
    && mv "$Q/$group/target.tmp" "$Q/$group/target"
  setsid "$HOME/ci/run-group.sh" "$group" "$GL_REPO" "$BARE" "$branch" \
    </dev/null >/dev/null 2>&1 &
done
```
The runner reads `event sha` from `target`. For `create`/`push` it checks out
`sha` and runs the manifest job whose `on:` matches the event. For `delete` it
runs teardown from the persisted env cache (§14) — it does NOT try to check out
the vanished branch.

### runner — flock + re-read = coalesce
```sh
#!/usr/bin/env bash
# run-group.sh <group> <repo> <bare-git-dir>
set -euo pipefail
group="$1"; repo="$2"; bare="$3"
Q="$HOME/ci/queue/$group"; RUNS="$HOME/ci/runs/$group"
SECRETS="$HOME/ci/secrets/$repo"; MAX=4

exec 9>"$Q/group.lock"
flock -n 9 || exit 0       # already running this group → holder will pick up newest

acquire_slot() {           # global cap across repos
  for i in $(seq 1 "$MAX"); do
    exec 8>"$HOME/ci/slots/$i"; flock -n 8 && return 0
  done; return 1
}
until acquire_slot; do sleep 2; done   # hold fd 8 until process exit (auto-released)

while :; do
  target="$(cat "$Q/target")"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$RUNS/$ts-${target:0:8}"; mkdir -p "$dir"
  echo running > "$dir/status"

  # fresh checkout per run (avoids wrong-sha races between branches)
  work="$(mktemp -d)"; git clone -q "$bare" "$work"; git -C "$work" checkout -q "$target"

  # read manifest: image + run command (parse .gitolite/ci.yml with yq)
  img="$(yq -r '.jobs.*.image' "$work/.gitolite/ci.yml" | head -1)"
  cmd="$(yq -r '.jobs.*.run'   "$work/.gitolite/ci.yml" | head -1)"

  name="ci-${group//\//-}-$ts"
  printf 'docker run --rm --init --name %q -v %q:/app -w /app --env-file %q %q sh -c %q\n' \
    "$name" "$work" "$SECRETS/cloudflare.env" "$img" "$cmd" > "$dir/cmd"

  timeout --signal=TERM --kill-after=30 600 \
    docker run --rm --init --name "$name" \
      --security-opt no-new-privileges --cap-drop ALL --pids-limit 512 --memory 2g \
      --label ci=1 --label "ci.group=$group" \
      -v "$work:/app" -w /app --env-file "$SECRETS/cloudflare.env" \
      "$img" sh -c "$cmd" > "$dir/output.log" 2>&1
  st=$?
  if [ "$st" -eq 124 ] || [ "$st" -eq 137 ]; then
    docker rm -f "$name" 2>/dev/null || true   # guarantee container gone (CLI-kill may orphan)
    echo timeout > "$dir/status"
  else
    echo "exit:$st" > "$dir/status"
  fi
  ln -sfn "$dir" "$RUNS/latest"
  rm -rf "$work"
  [ "$st" -eq 0 ] || notify_failure "$group" "$dir"   # §10 item 7

  # coalesce: newer push during the run? loop to newest, skipping intermediates
  [ "$(cat "$Q/target")" = "$target" ] && break
done
```

### Cancel-in-progress variant (faster-to-latest for deploys)
```sh
# post-receive, on new push for an active group:
docker kill "ci-${group//\//-}-"* 2>/dev/null || true   # superseded → abort; runner loops to newest
```
A superseded deploy is wasted compute, so cancel is arguably *more* correct than
coalesce for deploys. Cost: partial logs (mark `status=cancelled`).

---

## 8. Timeouts (stuck-job kill & reclaim)

**There is no docker-native max-runtime.** `--stop-timeout` is only the grace
period between `docker stop`'s SIGTERM and SIGKILL — not a wall-clock cap. The
daemon has no "kill after N seconds" (k8s has `activeDeadlineSeconds`; plain
docker doesn't).

**The trap:** `timeout 600 docker run …` kills the docker *CLI client*; the
container can keep running in the daemon. The CLI forwards SIGTERM → PID1, but if
the process ignores it, `timeout` escalates to SIGKILL *on the CLI* (can't be
forwarded) → orphaned container. **Never trust signal forwarding — always force
remove by name** (`docker rm -f "$name"`), as shown in §7.

- `--init` → tini as PID1, reaps zombies (npm spawns children).
- Slot/lock release must be guaranteed on exit (fds auto-released on process
  exit; or use `trap … EXIT`) so a timed-out job reclaims its semaphore slot.

---

## 9. Secrets

- Not in Dockerfile, not in repo, not in build args. Inject at **runtime** via
  `--env-file "$SECRETS/<repo>/<ns>.env"`, chmod 600. Gone when the container dies.
- Manifest `secrets: [cloudflare]` declares which namespaces a job may read.
- `~/ci/secrets/<repo>/cloudflare.env`:
  ```sh
  CLOUDFLARE_API_TOKEN=...    # Cloudflare Pages:Edit scoped token
  CLOUDFLARE_ACCOUNT_ID=...
  ```
- **Honest caveat:** `--env-file` env is visible via `docker inspect`. On a
  single-tenant VPS that's "root sees root" — acceptable. If it ever matters,
  mount a secret *file* read-only and have the script read it, instead of env.
- Optional future: `sops`+`age` encrypted secrets committed in-repo, runner
  decrypts with a host key at runtime — auditable, travels with the project.

---

## 10. Operational gaps a hand-rolled runner MUST own

These are what Laminar / real CI give free. None are dealbreakers; each must be
built. This list IS the full scope.

1. **Orphan reaping.** Runner crash mid-run → container lives forever, holds a
   slot. Reaper cron: `docker ps -q --filter label=ci` and `docker rm -f`
   anything older than max-timeout.
2. **Hung-but-not-timed-out.** Wall cap doesn't catch "no output for 9 min."
   Optional heartbeat watchdog on `output.log` mtime. Usually skip for deploys.
3. **Disk fills, two ways.** (a) run dirs grow → retention cron (keep last K per
   group, or prune > N days). (b) images/cache → `docker image prune` +
   `docker builder prune` on a schedule. **This one bites everyone.**
4. **Secrets visible in `docker inspect`** — see §9.
5. **Stale checkout / wrong-sha races.** Use **checkout-per-run** (mktemp, as in
   §7) unless disk/speed hurts — avoids deploying the wrong sha.
6. **Crash recovery / at-least-once.** Runner dies after push recorded, before
   run → on restart, startup sweep: for each group, if `target` ≠ last-run sha,
   run it. Otherwise a deploy silently never happens.
7. **Failure notification.** post-receive returns success even if deploy fails
   (detached). Add a failure ping (email/webhook/`wall`) — one line in the
   failure branch.

**Scorecard:** timeout, concurrency, logs, grouping, reaping, retention = all
cheap with docker + flock + cron, on-disk, on-ethos. The tax is items 6–7 plus
the discipline to actually write the reaper/prune crons. Skip those and it works
until the day it doesn't, silently.

Total estimated scope: **~250 lines bash + 3 cron jobs.** Not a moving target.

---

## 11. Migration path (the door we keep open)

The convention is *designed* so the only throwaway is the ~150 lines of runner
glue. Two future exits:

1. **Adopt Actions** (GitHub / Gitea / Forgejo): copy `ci/*.sh` verbatim into a
   ~10-line workflow (§4). Zero logic rewrite. Gives web UI, history, secrets
   vault, status — at the cost of a binary + DB (Gitea/Forgejo) or cloud (GitHub).
2. **gitolite → forge sync**: keep gitolite canonical, `post-receive` mirrors to
   Gitea/Forgejo, let its Actions run CI. Keeps the gitolite access model; adds a
   sync hop + a second system. See the Gitea-vs-Forgejo notes (separate).

---

## 12. Open decisions (to settle before building)

- **Runner robustness:** minimal bash (~150 lines, 1–5 projects) vs small Python
  service (queue, retries, systemd, 10+ projects). Leaning: start bash, upgrade
  if it hurts.
- **Docker privilege:** isolate (hook enqueues, separate runner user runs) vs git
  user runs docker inline (simplest, but root-equivalent exposure) vs rootless
  docker. Leaning: isolate, or rootless if paranoid.
- **Backlog semantic:** coalesce vs cancel-in-progress. Leaning: cancel for
  deploys.
- **Manifest path:** decided → `.gitolite/ci.yml` (logic stays neutral in `ci/`).

---

## 13. Research findings (web, 2026-06-21)

Deep-research fan-out (Sonnet sub-agents) across blogs/docs/HN/gists for prior
art on "bone-simple" CI. Full source lists below; here are the deltas that change
or confirm the design.

### A. Prior art that validates the approach
- **dokku** (push-to-deploy PaaS) uses exactly our model: `flock -n` on a
  per-app `.deploy.lock` in the receive hook. Confirms group+flock.
  Gotcha it hit: a build killed mid-flight leaves a stale lock sentinel →
  needs manual unlock. Lesson: the kernel `flock` auto-releases on process
  death, but if you *also* keep a sentinel/PID file, write logic to detect &
  clear stale ones. Source: dokku architecture docs + issue #2883.
- **piku** (~1500-line Python PaaS): run history as plain timestamped log files
  (`{app}/{ts}-{commit}.log`), `latest` symlink, secrets in an on-disk `ENV`
  file outside the repo. Exactly our `runs/` layout + symlink + `--env-file`.
- **Laminar** confirms the *config-as-files* convention (`cfg/jobs/$JOB.{run,
  before,after,init,conf,env}`) and a clean **job lifecycle**: `before → run →
  after` where `after` ALWAYS runs and carries `$RESULT`. Worth stealing for our
  `ci/*.sh` (an optional `ci/after.sh` for cleanup/notify on success+failure).
- **sethdowden / thomasfr / noelboss** writeups: the canonical ~20-line
  post-receive. Every minimal version omits the same four things — **locking,
  log persistence, run history, timeouts** — which is precisely the scope §7–§10
  already covers. We're filling the known gaps, not missing them.
- **adnanh/webhook**: confirmed only needed for the *multi-host* HTTP-trigger
  pattern. Single-VPS → direct hook. (Matches §2.)

### B. Concrete fixes to apply to our code
1. **`docker build` writes to stderr, not stdout.** Any build output capture must
   be `... 2>&1 | tee "$dir/output.log"`. (We use `> output.log 2>&1` on
   `docker run`, which is fine; note this if we ever add a build stage.)
2. **`tee` masks failures.** With a pipe, `$?` is `tee`'s exit (always 0).
   Capture `${PIPESTATUS[0]}` on the *very next line*. (Our §7 redirects without
   a pipe, so `$?` is correct — keep it that way, or use PIPESTATUS if a pipe is
   introduced.)
3. **Tag images by commit** when a project does build an image:
   `img="$repo:${target:0:8}"` → trivial rollback (`docker run repo:<sha>`).
4. **Branch deletion is a teardown TRIGGER, not a skip** (`newrev == 000…`).
   It fires post-receive too — we classify it as a `delete` event and run
   teardown of that branch's ephemeral environment. See §14. (Earlier drafts
   said "guard and skip" — that was wrong for the per-branch-env use case.)
5. **Use `$GL_USER` / `$GL_REPO`** (gitolite sets both in the hook env) for the
   `meta.json` audit header — who pushed, which repo — without path parsing.
6. **Disk guard before each run** (the #1 silent killer): abort/prune when
   `/var/lib/docker` > 80%. Plus a daily cron:
   `docker builder prune --keep-storage 10g --filter until=48h -f` +
   `docker image prune -f`. NEVER `system prune -a` per-job (nukes layer cache).
   Optionally set BuildKit GC in `buildkitd.toml` (`reservedSpace`,
   `maxUsedSpace`, `minFreeSpace`).
7. **Global json-file log rotation** in `/etc/docker/daemon.json`
   (`max-size=10m`, `max-file=3`) as a backstop — defaults are *unlimited*.
8. **Reaper must also sweep `status=dead`** (OOM-killed), not just `exited`, and
   use `xargs -r` (empty input otherwise errors and trips cron alerts).
9. **Don't rely on `--rm` alone** for cleanup: a daemon crash or CLI-kill bypasses
   it. The §10.1 reaper cron is the required backstop, not optional.

### C. Alternative timeout pattern worth considering
Instead of `timeout … docker run`, the **detach + poll + explicit stop** pattern
avoids the CLI-orphan problem entirely:
```sh
cid=$(docker run -d --name "$name" --label ci=1 ... "$img" sh -c "$cmd")
start=$(date +%s)
while [ "$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)" != "exited" ]; do
  [ $(( $(date +%s) - start )) -ge 600 ] && { docker stop "$cid"; break; }
  sleep 5
done
st=$(docker inspect -f '{{.State.ExitCode}}' "$cid")
docker logs "$cid" > "$dir/output.log" 2>&1   # logs survive because no --rm yet
docker rm -f "$cid"
```
Trade-off vs §7: no `--rm` race on logs, cleaner orphan handling, but you manage
removal yourself and poll every 5s. Either is fine; pick one and be consistent.

### D. The one Laminar anti-lesson
Laminar stores logs as **gzip blobs inside SQLite**, which (a) blocks its
single-threaded daemon on write for large logs (issue #192), (b) makes
`grep`/`tail` impossible, (c) has no prune CLI (issue #152, open since 2020), and
(d) hit 12 GB DB at ~48k runs. **This is exactly what our "filesystem is the
dashboard" choice avoids.** Plain `.log` files + `find -mtime +30 -delete`
retention is strictly better for our scale. Confirmation we picked right.

### E. Concurrency primitives confirmed
- `flock -n` (fd-based, auto-release on death) for per-group serialization. ✓
- Counting semaphore options for the global cap: FIFO-token pattern, GNU
  `parallel --sem --id`, or `xargs -P`. Our `slots/` flock-array (§7) is
  equivalent and on-ethos.
- Hardening flags all confirmed by OWASP/CIS: `--cap-drop ALL`,
  `--security-opt no-new-privileges`, `--pids-limit`, `--memory`+`--memory-swap`,
  `--network none` (deploy needs net; a pure build step can use it), non-root
  `-u`, `--read-only --tmpfs /tmp`. (Matches §7/§9.)

### Sources
- git-hook + docker push-to-deploy: thomasfr gist 9691385; noelboss gist
  3fe13927; symbioquine.net (2021); sethdowden.com; DigitalOcean git-hooks
  tutorial; cloud66 gitolite-in-docker; gitolite.com/cookbook.
- adnanh/webhook: github.com/adnanh/webhook; willbrowning.me; kitemetric.com.
- PaaS prior art: dokku.com/docs/development/architecture + issue #2883;
  piku/piku source.
- Laminar: laminar.ohwg.net/docs.html; github.com/ohwgiles/laminar
  (UserManual.md, issues #152/#192/#194); experience reports tyil.nl (2023),
  monotux.tech (2024), starbeamrainbowlabs.com; HN 18373449.
- docker ops: docs.docker.com (run/stop/secrets/json-file/resource-constraints/
  pruning); krallin/tini; OWASP Docker Security Cheat Sheet; pythonspeed.com
  build-secrets; moby/moby #15397/#29700 (CLI-orphan); docker/buildx #3006;
  CIS Docker 5.28 (pids-limit); 7tonshark.com (bash semaphore).
- log capture: PIPESTATUS — baeldung.com/linux/exit-status-piped-processes;
  docker build→stderr — forums.docker.com t/123178.

> Gitea vs Forgejo — see §15 (research complete).

---

## 14. Ephemeral per-branch environments (create / update / teardown)

A first-class use case, not an afterthought: each dev/experiment branch gets its
own isolated environment, spun up on branch creation, updated on push, and
**torn down on branch deletion**. This is the Vercel/Netlify "preview env" /
Heroku "Review Apps" model. Branch deletion is the teardown trigger.

### Event model (3 events, from §7 hook)
| git action | oldrev/newrev | event | typical job |
|---|---|---|---|
| push new branch | `000…` → sha | **create** | provision isolated env |
| push to branch | sha → sha | **push** | deploy/update env |
| delete branch | sha → `000…` | **delete** | **tear down env** |

In practice `create` and `push` usually run the **same idempotent
"deploy-or-update" script**, so most projects only need two scripts: a deploy and
a teardown.

### Manifest — event-keyed jobs
```yaml
version: 1
jobs:
  preview:
    on:
      create: { branches: ["feat/*", "exp/*"] }
      push:   { branches: ["feat/*", "exp/*"], paths: ["site/**"] }
    image: node:20-alpine
    secrets: [cloudflare]
    run: sh ci/preview-deploy.sh      # idempotent create-or-update
  preview-teardown:
    on:
      delete: { branches: ["feat/*", "exp/*"] }
    image: node:20-alpine
    secrets: [cloudflare]
    run: sh ci/preview-teardown.sh
```

### Branch context passed into the container
The runner injects (env vars, available to every `ci/*.sh`):
- `CI_EVENT` — `create` | `push` | `delete`
- `CI_REPO` — repo name (`$GL_REPO`)
- `CI_BRANCH` — raw branch name (`feat/foo-bar`)
- `CI_BRANCH_SLUG` — DNS-safe deterministic slug (resource name)
- `CI_SHA` — `newrev` (create/push) or `oldrev` (delete)
- `CI_PUSHER` — `$GL_USER`

**Slug rule** (deterministic, collision-resistant, DNS-safe):
```sh
# feat/Foo_Bar#42  ->  feat-foo-bar-42-a1b2c3
slug() {
  raw="$1"
  base="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//' | cut -c1-40)"
  h="$(printf '%s' "$raw" | sha1sum | cut -c1-6)"   # disambiguate truncation/charset collisions
  printf '%s-%s' "$base" "$h"
}
```
Scripts name every resource off `CI_BRANCH_SLUG` (container name, subdomain,
Cloudflare Pages branch alias, allocated port, DB schema) so create and teardown
agree on names without shared mutable state.

### The teardown-source problem & the fix (persist-on-provision)
**Problem:** on `delete` the ref is gone. You can't check out the branch to read
its `.gitolite/ci.yml` or `ci/preview-teardown.sh`. Worse, **bare repos default
to `core.logAllRefUpdates=false`** → no reflog → the deleted branch's objects are
immediately unreachable and a `git gc`/`prune` can drop them. So teardown logic
must NOT depend on the branch's git objects surviving.

**Fix — cache the destroy plan + state when you provision** (Terraform-style:
keep your teardown next to your state). On every `create`/`push` run, the runner
persists, on disk, outside git:

```
~/ci/envs/<repo>/<slug>/
  teardown.sh     # copied from the checked-out ci/preview-teardown.sh
  image           # image to run teardown in (from manifest)
  secrets         # which secret namespaces teardown needs
  state           # what was provisioned (written BY the deploy script)
  meta.json       # branch, slug, first_seen, last_sha, last_event_at
```

`state` is written by `ci/preview-deploy.sh` (it knows what it created):
```sh
# inside ci/preview-deploy.sh, after provisioning:
cat > "$CI_ENV_DIR/state" <<EOF
container=preview-$CI_BRANCH_SLUG
url=https://$CI_BRANCH_SLUG.preview.example.com
pages_alias=$CI_BRANCH_SLUG
port=$port
EOF
```
(`$CI_ENV_DIR` = `~/ci/envs/<repo>/<slug>`, bind-mounted into the container so the
script can read/write it.)

On `delete`, the runner runs the **cached** `~/ci/envs/<repo>/<slug>/teardown.sh`
in the cached image with the cached secrets — never touching git. The script
reads `state`, destroys those named resources, exits 0. Then the runner
`rm -rf`s the env dir. Teardown is **idempotent**: if the env dir is missing
(branch never provisioned, or already torn down), it's a no-op success.

> Fallback if you'd rather not persist: `git checkout $oldrev` (the tip still
> exists *in the gc window*). Works often, fails silently after gc. **Not
> recommended** — persist-on-provision is the robust choice. If you do rely on
> oldrev, set `git config gc.pruneExpire 2.weeks.ago` and/or
> `receive.denyDeletes`-aware GC scheduling on the bare repo to widen the window.

### The PRIMARY mechanism (implemented): a server-side preservation ref
persist-on-provision only saves `ci/` — insufficient if teardown logic needs other
project parts (`infra/`, compose files, terraform, etc.). The robust fix gives
teardown the **entire tree** of the deleted branch, without blocking the push:

When `post-receive` fires on a delete, **the branch ref is gone but the objects
still exist** — git auto-gc runs only *after* hooks, never mid-hook. So the hook
instantly pins the tip under a hidden ref (no copy, ~40 bytes, invisible to normal
clients — `refs/cicd/*` is outside `refs/heads`):
```sh
git update-ref refs/cicd/preserve/<slug> <oldrev>   # in post-receive, on delete
```
This keeps the FULL tree reachable past gc. The push returns immediately (the hook
only pins + enqueues; teardown runs async). The runner's teardown then:
```sh
git archive refs/cicd/preserve/<slug> | tar -x -C $work   # whole project tree
# run the on.delete job from $work (/work) with the state dir at /envstate
git update-ref -d refs/cicd/preserve/<slug>               # release → gc may reclaim
```

**Two things survive a delete, two ways:**
- **Code** (full tree) → the preserve ref (git-native, no copy).
- **Runtime state** (provisioned URLs/IDs/ports — NOT in git) → written by the
  deploy script to `envs/<slug>/state` on the runner. Teardown gets both: tree at
  `/work`, state at `/envstate`.

**Fallback chain (run_teardown):**
1. preserve ref → full tree (normal `git push --delete`). ✅ primary
2. no ref but `oldrev` objects present (gc window) → archive oldrev → full tree.
3. neither (reap-envs for a branch deleted server-side bypassing hooks) → minimal
   mode: persisted `ci/` + `state` only (teardown script must work from state).
4. nothing → exit 0 + log.

**Failure handling:** if teardown exits non-zero, the preserve ref AND env state
are KEPT (not deleted) so it can be retried; success deletes both. So a failed
teardown never strands you without the code.

### Stuck-teardown lifecycle (a teardown that fails)
Deliberately **minimal automation**: one retry for transient blips, then the
operator owns it. No quarantine ladder, no daily auto-retry loop.

1. **One automatic retry** — `run_teardown` runs the teardown up to
   `1 + TEARDOWN_RETRIES` times (default 2 total), `TEARDOWN_RETRY_DELAY` apart.
   Catches intermittent network errors (Cloudflare API hiccup, DNS blip).
2. **Then: notify + stop** — if it still fails, the runner writes
   `envs/<slug>/teardown-failed` (exit code, time, log path), fires
   `notify_failure` (→ operator), and KEEPS the preserve ref + env state. **No
   further automatic retry.** The full tree + runtime state stay intact for the
   human.
3. **`reap-envs` is a missed-delete catcher, not a retry loop** — it triggers a
   *first* teardown only for branches deleted server-side bypassing the hook; it
   **skips** any env already marked `teardown-failed`.
4. **Operator resolves** — `ci-status` lists failed teardowns; `ci-teardown
   retry <repo> <branch>` clears the marker and fires again; `ci-teardown abandon
   <repo> <branch>` force-releases the ref + deletes env state (warning: real
   provisioned resources are NOT auto-cleaned).

So: a transient failure self-heals via the single retry; anything real lands in
the operator's inbox and waits — the preserve ref is never auto-released, so the
human always has the full tree to finish the job.

### Concurrency: delete supersedes deploy
A `delete` for a group is **terminal** and must win over any in-flight or queued
deploy for that same group:
1. On `delete`, cancel-in-progress: `docker kill` the group's running deploy
   container (a superseded preview deploy is wasted anyway).
2. Run teardown.
3. The coalesce loop (§7) must treat `delete` as a final target — do **not** loop
   back into a deploy even if an older `push` is still recorded. Rule: if the
   newest `target` event is `delete`, teardown wins; drop any pending deploy.

### Teardown script — what it owns (example)
```sh
#!/usr/bin/env sh
# ci/preview-teardown.sh — runs on branch delete; reads $CI_ENV_DIR/state
set -eu
[ -f "$CI_ENV_DIR/state" ] || { echo "no env for $CI_BRANCH — nothing to tear down"; exit 0; }
. "$CI_ENV_DIR/state"
# stop/remove the per-branch container (idempotent)
docker rm -f "$container" 2>/dev/null || true
# delete the Cloudflare Pages preview deployment(s) for this branch alias
npx wrangler pages deployment list --project-name=pipelineforge-site \
  | awk -v a="$pages_alias" '$0 ~ a {print $1}' \
  | xargs -r -n1 npx wrangler pages deployment delete --yes 2>/dev/null || true
# free any other resources: DNS record, DB schema, allocated port…
echo "torn down $CI_BRANCH"
```
Note: Cloudflare **Pages** auto-creates a per-branch preview alias on deploy, so
"create" for a static site may be free (the branch alias appears on first
deploy). Teardown deletes the stale preview deployments. For richer envs
(long-running containers, DBs, subdomains) the deploy script provisions and the
teardown script destroys — the runner only guarantees teardown.sh runs with
branch context + cached state.

### Garbage collection of orphaned envs (safety net)
A teardown can be missed (runner down during the delete push, or a branch deleted
directly on the server bypassing the hook). Reaper cron: for each
`~/ci/envs/<repo>/<slug>/`, if the branch no longer exists in the bare repo
(`git show-ref --verify --quiet refs/heads/<branch>` fails) and `meta.json`
`last_event_at` is older than N days, run its cached `teardown.sh` and remove the
dir. This catches leaks the same way the container reaper (§10.1) does.

### Scope check
This adds: the 3-event hook (done, §7), event-keyed manifest parsing, the
`CI_*` env injection + slug, the `~/ci/envs/` persist-on-provision cache, the
delete-supersedes-deploy rule, and the orphaned-env reaper. ~80–100 lines on top
of the base runner. Still bash, still on-disk, still no DB. The env cache dir IS
the state store — greppable, `ls`-able, on-ethos.

---

## 15. Gitea vs Forgejo (only relevant if we pick the "sync to a forge" path, §11.2)

Both are forks in a chain: **Gogs → Gitea → Forgejo**. Relevant only if we ever
front gitolite with a forge to get a CI web UI. Neither is on-disk-plaintext like
gitolite — **both are a Go binary + a database** (the §11 transparency caveat
stands for either).

### How the forks happened
- **Gogs** (Go Git Service) was effectively a **single-maintainer** project
  (Jiahua "Joe" Chen, @Unknwon). Frustration with one person gatekeeping
  contributions led to a community fork.
- **Gitea** forked from Gogs in **Nov 2016** (fork tag v0.9.99 on 2016-11-17;
  v1.0.0 on 2016-12-24), explicitly to "set the code effectively free" under
  collaborative governance — elected owners (Lunny Xiao, Thomas Boerger, Kim
  Carlbäcker) + an open maintainer pool. Permissively **MIT** licensed.
- **The 2022 rupture:** a for-profit **Gitea Limited** was incorporated (Hong
  Kong, ~March 2022 — *flagged uncertain*), and on **2022-10-24** announced it
  was taking over the Gitea **trademark, domains, and assets**. The community
  objected: an open project's control moved to a private company without full
  consultation; the plan floated a DAO + a 6-seat oversight committee with 3
  company-appointed seats. One of the three elected owners (@zeripath) opposed it
  and was not a shareholder. (Successor entity: CommitGo, Inc., Delaware.)
- **Forgejo** was created **Dec 2022** by **Codeberg e.V.**, a German non-profit,
  as a hard guarantee against corporate capture. Name = Esperanto *forĝejo*
  ("forge"). Deliberately no single founder (Dachary, Manivannan, Gusted, fnetX).

### Soft-fork → hard-fork, and the licensing split
- Forgejo began as a **soft fork** (regularly merging Gitea downstream). Over
  2023–2024 it became a **hard fork** — independent development, not a drop-in
  downstream of Gitea anymore.
- Around **v9.0 (2024)** Forgejo relicensed new code to **GPLv3+** (copyleft) vs
  Gitea's **MIT** (permissive). For an anti-capture stance this is the crux:
  copyleft structurally prevents a future *proprietary* fork of the forge.
  Migration **Gitea → Forgejo stays easy**; the reverse is no longer guaranteed.
- **Fedora adopted Forgejo (Dec 2024)** — a notable institutional endorsement.

### Built-in CI: near-identical, both GitHub-Actions-shaped
- **Gitea Actions** (`act_runner`, `.gitea/workflows/`) and **Forgejo Actions**
  (`forgejo-runner`, a fork of act_runner, `.forgejo/workflows/`) both run
  **GitHub-Actions-compatible YAML** and reuse many marketplace actions.
- This is the payoff for §4's convention: our portable `ci/*.sh` drop straight
  into either with a ~10-line workflow wrapper. Runner executes each job in a
  container = the sandbox requirement, free.
- Maturity: Gitea Actions had a head start; Forgejo Actions is solid and actively
  developed. For a simple build→deploy, both are more than enough.

### Choose Gitea if…
- You want the larger ecosystem / marketshare and **commercial backing** (Gitea
  Cloud, paid support), and MIT permissiveness is a feature for you.
- You're fine with a company stewarding the project.

### Choose Forgejo if…
- You value **community/non-profit governance** (Codeberg e.V.), **copyleft**
  (GPLv3+) as a capture-proof guarantee, and the **ActivityPub federation**
  roadmap.
- You're philosophically where this whole design has been pointing (open, light,
  anti-blackbox, anti-corporate-capture).

### Recommendation for *this* setup
Given the stated values (gitolite ethos: open, lightweight, community,
anti-capture), **Forgejo** is the aligned choice *if* we ever adopt a forge.
Codeberg non-profit + copyleft + Fedora's endorsement match the philosophy; the
GH-Actions-compatible CI keeps our scripts portable.

**But note the meta-point:** adopting *either* forge means accepting a binary +
DB, which is the exact thing the custom-runner path (§3–§14) exists to avoid. So
the honest framing: **custom runner = the on-ethos default; Forgejo = the exit
ramp** if/when you decide a clickable UI + secrets vault + status checks are worth
trading away full on-disk transparency. Don't adopt a forge for CI alone while
the filesystem-dashboard runner still satisfies the need.

*Sourced facts (Gitea/Forgejo blogs, Codeberg, HN/Lobsters, Wikipedia,
Dachary "Sustainability Smokescreen"). Flagged uncertain: Gitea Ltd. exact
jurisdiction/date; the GPL-relicense-as-anti-Gitea and "Earl Warren pseudonym"
claims are single-source/denied — not relied upon here.*

---

## 16. Security: the docker-socket trust boundary (applies to EVERY option)

The single most important security fact, and it is **not specific to any one
tool** — it's true for Laminar, Gitea/Forgejo `act_runner`, and our own custom
runner equally. Whoever can do `docker run` can become root on the host.

### Laminar specifically (researched 2026-06-21)
- **No turnkey image.** Official repo ships a build-from-source
  `docker/Dockerfile` (alpine:edge, runs as non-root `laminar`, tini PID1). No
  prebuilt image on any registry. Only community option `mapperr/laminar`
  (~762 pulls, ~2yr stale). Real-world users run laminard **natively on host**.
- **Laminar runs job scripts directly on the host, as the `laminar` user, with
  ZERO built-in sandboxing.** Docs, verbatim: *"Laminar will not drop privileges
  when executing job scripts!"* and *"Laminar provides no specific support [for
  isolation], but just like remote jobs these are easily implementable in plain
  bash."* Isolation is 100% the operator's job — the `.run` script must itself
  call `docker run`.
- **Putting laminard in a container does not fix this — it relocates the risk.**
  For jobs to sandbox via `docker run`, the laminard container must mount
  `/var/run/docker.sock` → *"the same capability to any process in that
  container"* = root-equivalent host access. You trade "shell on host" for
  "root-equiv Docker API on host." Same blast radius, harder to audit.

### The universal consequence
1. **Against Laminar for our use case:** it gives *no isolation for free*. You'd
   write the exact same `docker run` job scripts our runner already centralizes —
   so Laminar buys you a C++ daemon + a sqlite-log wart (§13.D) on top of work
   you're doing regardless. Our custom runner ≈ "Laminar's docker-run job pattern,
   minus the daemon, plus plaintext on-disk logs."
2. **For our runner (and any CI):** the isolation lever is NOT the orchestrator —
   it's *how docker is granted*. This is the real content of the §12
   "docker privilege" open decision. Ranked:
   - **Rootless docker** (`docker:dind-rootless` / rootless engine) — daemon runs
     unprivileged; a socket compromise ≠ host root. **Best practical default.**
   - **Socket proxy** (`tecnativa/docker-socket-proxy`) — whitelist API calls
     (allow build/run, deny exec/secrets/delete). Shrinks attack surface.
   - **Kaniko / Buildah** — daemonless image *builds*, no socket at all. Helps the
     build step only, not arbitrary `docker run`.
   - **Ephemeral VM per job** — strongest isolation, heaviest to operate.
   - Plain socket mount on a single-tenant low-risk VPS — acceptable only if you
     accept "anyone who can trigger a build can root the box." Fine for a
     solo/trusted setup; not for untrusted contributors.

### Updated recommendation for §12 "docker privilege"
Default to **rootless docker** for the runner user. It directly answers the
original "I don't want CI code exposing the host" worry in a way that NO
orchestrator (Laminar included) provides on its own. The hardening flags (§7:
`--cap-drop ALL`, `no-new-privileges`, `--pids-limit`, `--memory`,
`--network none` for build) layer on top — defense in depth, but rootless is the
one that contains a socket-level compromise.

---

## 17. Rootless ≠ no network; set network per STEP (build vs deploy)

Clarification — two independent knobs, often conflated:

| Knob | Controls | Independent of |
|---|---|---|
| rootless vs rootful | whether the **daemon** runs as root | container networking |
| `--network none` vs default | whether **this container** has network | rootless/rootful |

- **Rootless docker has full outbound networking.** It routes through a userspace
  stack (`slirp4netns` / `pasta`), slightly lower throughput, but
  `wrangler → Cloudflare API` works fine. DNS + outbound just work. Only *inbound*
  published ports (esp. <1024) need extra config — irrelevant for an
  outbound-only deploy. **So rootless + deploy = works. You lose nothing.**
- `--network none` is a per-container flag — apply it where it fits, drop it where
  it doesn't. The **deploy step needs network** (default bridge); a **build step**
  can be air-gapped *only if its deps are pre-fetched*.

### The catch: `npm ci` needs network too
The build pulls from the npm registry, so `--network none` on the build only
works if deps are pre-fetched. Two options:

1. **Two-phase air-gapped build** (max isolation):
   ```sh
   docker run --rm -v cache:/root/.npm "$img" npm ci                        # net, fills cache
   docker run --rm --network none -v cache:/root/.npm "$img" npm run build  # air-gapped
   ```
2. **Pragmatic** (default for a deploy pipeline): build needs net → drop
   `--network none`; contain via rootless + `--cap-drop ALL` +
   `no-new-privileges` + `--pids-limit` + `--memory`.

### The real least-privilege win for deploy
Not network isolation (deploy needs net) — a **tightly-scoped Cloudflare token**
(Pages:Edit on the one project only). A compromised job then can't do more than
deploy that single project. Scope the token; don't reuse a global one.

---

## 18. Dependency caching (fast installs, safely)

Each job is a throwaway `docker run --rm`, so a naive `npm ci` re-downloads every
time. Cache like GitHub Actions does — but note a safety subtlety GitHub glosses
over: **the package-manager store is integrity-verified and safe to share; an
arbitrary result cache is not.**

### Two cache types, different safety
| Cache | What | Safe to share across trust boundary? |
|---|---|---|
| `~/.npm` (cacache store) | downloaded tarballs, content-addressed | **YES** — `npm ci` verifies each tarball against the lockfile SRI hash; mismatches rejected. Can't poison without a hash collision. |
| `node_modules` result cache | extracted install output, plain files | **NO** — restore is just untar, no verification. Untrusted build can poison it → a later trusted build runs the poison. The real cache-poisoning attack class. |

Principle: **share the store freely; be careful with result caches.**

### Win #1 — mount the npm store (simple, safe, biggest payoff)
Persistent per-repo store, integrity-checked, no key management (content-addressing
IS the key):
```sh
WARM="$HOME/ci/cache/$repo/npm"; mkdir -p "$WARM"
docker run --rm -e npm_config_cache=/cache -v "$WARM:/cache" \
  -v "$work:/app" -w /app "$img" \
  sh -c "npm ci && npm run build && npx wrangler pages deploy dist ..."
```
cacache is concurrency-safe; per-group flock (§7) already serializes a repo's own
runs.

### Win #2 — node_modules result cache, keyed by lockfile, TRUSTED-WRITE-ONLY
GitHub's `key: npm-{{ hashFiles('package-lock.json') }}` model:
```sh
key="$(sha256sum "$work/package-lock.json" | cut -c1-16)"
slot="$HOME/ci/cache/$repo/nm/$key.tar.zst"   # arch/node-version fixed by the image
[ -f "$slot" ] && tar -C "$work" -I zstd -xf "$slot"        # restore (anyone may READ)
docker run ... sh -c "npm ci --prefer-offline; npm run build && deploy"
if is_trusted "$branch" && [ ! -f "$slot" ]; then           # save: trusted + miss only
  tar -C "$work" -I zstd -cf "$slot.tmp" node_modules && mv "$slot.tmp" "$slot"
fi
```
**Untrusted experiment branches may restore but NEVER write** the shared keyed
cache. Changed lockfile → new hash → miss → fresh `npm ci` → (trusted) re-save.

### Safety rules
1. **Namespace per repo** (`cache/<repo>/…`) — no cross-project bleed.
2. **Store cache (`~/.npm`): RW for all** — integrity verification protects it.
3. **Result cache (node_modules): trusted writes, all read** — never let an
   experiment branch feed main's install.
4. **Prune** — caches grow; fold LRU/size-cap into the §10.3 disk cron (evict old
   lockfile-keyed tarballs first).
5. **Rootless-safe** — plain volume mounts, identical under rootless.

### Upgrades
- **pnpm** (if you control the project): content-addressed global store +
  hardlinks → near-instant installs, store is integrity-checked (safe to share),
  tiny disk. Strictly better than npm for caching. Mount its store the same way.
- **For image-shipping projects** (`docker build`): use BuildKit cache mounts —
  `RUN --mount=type=cache,target=/root/.npm npm ci` — daemon-managed, no manual
  volume. Only for the build-an-image path, not the `docker run` deploy path.

---

## 19. Secrets management, in depth (build-time secrets, .npmrc, at-rest storage)

Extends §9. The `.npmrc` private-registry token is the canonical build-time
secret; the clean handling generalizes to all of them.

### The clean .npmrc pattern — token never touches disk
npm natively expands `${VAR}` inside `.npmrc`. Commit a `.npmrc` referencing the
variable NAME (no secret); inject the token as runtime env:
```ini
# .npmrc — committed, contains NO secret
@myscope:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${NPM_TOKEN}
```
```sh
docker run --rm -e NPM_TOKEN -v "$work:/app" -w /app "$img" \
  sh -c "npm ci && npm run build && ..."
```
No file written, nothing to clean up. Beats "script writes .npmrc from a secret"
(which risks the token landing in `$work` or a log). If a tool lacks `${VAR}`
support, write the file to the container's ephemeral `$HOME`, never into `$work`
or a persisted cache volume.

### At-rest storage — two tiers
**Baseline (§9):** per-repo env-file namespaces. `~/ci/secrets/<repo>/<ns>.env`,
`chmod 600`, dir `700`, runner-owned, never in git. Trust = filesystem perms.
Plaintext on disk — the one place "transparent" and "safe" diverge. Acceptable on
a single-tenant VPS where root == you.

**Upgrade — sops + age (encryption at rest):** tiny, no service, on-ethos.
Encrypted secrets, can even be committed in-repo (`ci/secrets.enc.yaml`). Runner
decrypts at runtime; decrypted values land only in the command env, never a
plaintext file:
```sh
sops exec-env "$work/ci/secrets.enc.yaml" \
  'docker run --rm -e NPM_TOKEN -e CLOUDFLARE_API_TOKEN \
     -v "$work:/app" -w /app "$img" sh -c "npm ci && npm run build && deploy"'
```
The **age private key on the host is the single root of trust**
(`~runner/.config/sops/age/keys.txt`, mode 600).

### What encryption-at-rest actually buys (be honest)
Protects against: disk backups/snapshots, accidental plaintext git commit,
non-root users on the box. Does NOT protect against root compromise (root reads
the age key, runtime env, and `docker inspect`). On a solo VPS the real wins:
safe to commit secrets to git, safe backups, audit trail. If those don't matter,
env-files are honestly fine.

### Leak-surface checklist (build-time secrets)
1. Not in git — only the `${VAR}` reference or the sops-encrypted blob.
2. Not in image layers — we don't `docker build` for deploy. If ever building an
   image, use BuildKit `--mount=type=secret`, NEVER `ARG`/`ENV` (bakes into
   `docker history`).
3. Not in the cache volume — `.npmrc`/token live in throwaway `$work`, not in the
   mounted `~/.npm` store. cacache persists tarball content by integrity hash;
   auth is used only for the HTTP fetch, never stored. Safe.
4. Not in logs — no `set -x` around tokens, never `env`-dump.
5. `docker inspect` shows `-e` env (root-only) — accepted caveat (§9). For the
   most sensitive, prefer mounted secret files over `-e`, or accept it
   single-tenant.
6. Throwaway workdir `rm -rf`'d after the run (§7).

### Per-step scoping (least privilege)
Manifest declares `secrets: [npm, cloudflare]`. Tighten: the BUILD step gets
`NPM_TOKEN` only; the DEPLOY step gets `CLOUDFLARE_API_TOKEN` only — two
`docker run`s, each with just its env. A compromised build never sees the deploy
token, and vice versa. Pairs with the Pages:Edit-scoped token (§17): least
privilege at rest AND in scope.

---

## 20. Native Docker secrets — what exists, and why we don't run Swarm

**`docker run` has no native secret store.** Docker's real "secrets" feature is
**Swarm-only** and does not reach standalone `docker run`.

| Mechanism | Scope | Usable from `docker run`? |
|---|---|---|
| `docker secret` + `--secret` | Swarm services only | ❌ |
| `docker build --secret` (BuildKit) | build time only | ❌ |
| `docker compose` `secrets:` (non-Swarm) | Compose | ⚠️ just a file bind-mount, no encryption |
| `docker run -e` / `--env-file` | standalone | ✅ but visible in `docker inspect` |
| `docker run -v file:/run/secrets/x:ro` | standalone | ✅ best option |

- **Swarm secrets** are the only real store (encrypted at rest in Raft, tmpfs
  files at `/run/secrets/<name>`), but require `swarm init` + deploying as
  **services**, not `docker run`. Adopting Swarm for one feature = overlay net,
  Raft, service model — against the ethos. Rejected.
- **Compose non-Swarm `secrets:` are just read-only bind-mounts** from a host
  `file:` source. Nice syntax, zero encryption — it's the file-mount you already
  have.
- **BuildKit `--secret`** is build-only (§19).

### Steal the file-mount convention (beats `-e`)
A mounted file's CONTENTS are not shown in `docker inspect` (only `-e`/env is). So
emulate Swarm's `/run/secrets/<name>` file convention. Best form — decrypt to
tmpfs (`/dev/shm`, RAM-only), bind-mount read-only, entrypoint reads into env:
```sh
sec="$(mktemp -d -p /dev/shm)"                          # RAM-only scratch
sops -d --extract '["npm_token"]' "$work/ci/secrets.enc.yaml" > "$sec/npm_token"
docker run --rm \
  --mount type=bind,src="$sec/npm_token",dst=/run/secrets/npm_token,ro \
  "$img" sh -c 'export NPM_TOKEN=$(cat /run/secrets/npm_token); npm ci && npm run build'
rm -rf "$sec"
```
Result: token is encrypted at rest (sops/age), never on real disk (tmpfs), not in
`docker inspect` env (set inside the container), gone when the run ends. ≈ Swarm
secrets (at-rest encryption + tmpfs file delivery) WITHOUT Swarm, in ~3 lines.

Images supporting the `VAR_FILE` convention (e.g. `MYSQL_PASSWORD_FILE`) read the
file directly; for tools that don't (wrangler, npm) the `export VAR=$(cat …)` shim
does the same. This is the recommended delivery for the most sensitive secrets;
plain `-e`/`--env-file` (§9) stays fine for lower-sensitivity values on a
single-tenant box.

---

## 21. sops + age runbook (Mac author + Gentoo VPS runner)

Concrete setup for storing per-repo secrets encrypted IN the gitolite repo,
decryptable only by trusted environments. Verified package facts (2026):
- `age`: in main Gentoo tree (`app-crypt/age`, ships `age-keygen`).
- `sops`: NOT in main tree → pin static binary (GURU has it `~amd64` only).
- macOS: `brew install sops age`.
- Key file defaults: Linux `~/.config/sops/age/keys.txt`; macOS
  `~/Library/Application Support/sops/age/keys.txt`. Overrides: `SOPS_AGE_KEY_FILE`,
  `SOPS_AGE_KEY`, `SOPS_AGE_KEY_CMD`.

**Trust model:** one age keypair per environment; encrypt to the PUBLIC keys of
every env allowed to decrypt (Mac for editing + VPS runner for CI). Private keys
never leave their host. Ciphertext is safe in git.

### Install
```bash
# Mac
brew install sops age
mkdir -p "$HOME/Library/Application Support/sops/age"
age-keygen -o "$HOME/Library/Application Support/sops/age/keys.txt"   # record age1mac...
chmod 600 "$HOME/Library/Application Support/sops/age/keys.txt"

# Gentoo VPS — root
emerge --ask app-crypt/age
curl -LO https://github.com/getsops/sops/releases/download/v3.13.1/sops-v3.13.1.linux.amd64
install -m755 sops-v3.13.1.linux.amd64 /usr/local/bin/sops

# Gentoo VPS — as the CI runner user
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt    # record age1vps...
chmod 600 ~/.config/sops/age/keys.txt
```

### Repo config (`.sops.yaml`, committed)
```yaml
creation_rules:
  - path_regex: \.enc\.(ya?ml|json|env)$
    age: >-
      age1mac_xxxx,
      age1vps_yyyy
```

### Author / edit (Mac)
```bash
sops ci/secrets.enc.yaml    # $EDITOR; values encrypted on save, keys stay readable
git add .sops.yaml ci/secrets.enc.yaml && git commit -m "ci: encrypted secrets"
```

### Decrypt at runtime (VPS runner) — host-side, never inside the build container
```bash
sops exec-env ci/secrets.enc.yaml 'docker run --rm -e CLOUDFLARE_API_TOKEN -e NPM_TOKEN ...'
# or single value to tmpfs (file-mount, §20):
sec=$(mktemp -d -p /dev/shm); sops -d --extract '["npm_token"]' ci/secrets.enc.yaml > "$sec/npm_token"
```

### Rotate / add / remove recipient
```bash
# edit .sops.yaml recipients, then:
sops updatekeys ci/secrets.enc.yaml         # re-encrypts data key; values unchanged
# if a key is COMPROMISED, also rotate the secret VALUES themselves
```

### Critical gotchas
- **Always keep the Mac as a recipient** → a VPS rebuild (lost runner key) can't
  lock you out; re-decrypt from Mac, gen new VPS key, `updatekeys`. ≥2 recipients
  = losing one is recoverable.
- **Back up the Mac private key offline** — it's the master.
- `.sops.yaml` applies at create time; change recipients on existing files via
  `sops updatekeys`.
- Decrypt on the HOST; inject values into the container via `-e`/tmpfs mount.
  Never mount or copy the age key into the build container.

---

## 22. Multi-device / multi-recipient sops setup

Goal: edit/decrypt secrets from many places (Mac, new laptop, Android, VPS) —
without copying private keys around. sops is multi-recipient by design: encrypt to
many PUBLIC keys, ANY one private key decrypts.

### Two strategies → use the hybrid
- **A) One key per device** — each device gens its own age key; add each public
  key as a recipient. Max security, granular revoke. Cost: recipient list grows,
  roster changes need `updatekeys`.
- **B) One personal key synced via password manager** — gen one personal key,
  store the PRIVATE key in 1Password/Bitwarden, pull on each device. One recipient
  covers all your devices. Vault is the secure sync channel (not ad-hoc copying).
- **Hybrid (recommended):** one personal key PER PERSON (vault-synced, covers all
  their devices) + a dedicated key for EACH machine/CI (VPS runner, etc.). Revoke
  a person via their vault key; revoke a server by dropping its recipient.

### Password-manager pattern (multi-device convenience)
Store the personal age private key in the vault; feed sops on demand, never to
disk, via `SOPS_AGE_KEY_CMD` (stdout = the key):
```bash
# per device shell rc
export SOPS_AGE_KEY_CMD="op read 'op://Private/age-personal/private-key'"   # 1Password
# or: export SOPS_AGE_KEY_CMD="bw get notes age-personal"                   # Bitwarden
```
New machine = install sops+age, sign into vault, decrypt immediately.

### Android
- **Termux**: `pkg install age golang` → `go install github.com/getsops/sops/v3/cmd/sops@latest`.
  Gen a device key, or pull personal key from the Bitwarden/1Password Android app
  into `SOPS_AGE_KEY`.
- Editing YAML on a phone is awkward but mechanically identical — no special case.

### `.sops.yaml` roster (comment who's who; pubkeys are opaque)
```yaml
creation_rules:
  - path_regex: \.enc\.(ya?ml|json|env)$
    age: >-
      age1abc...,   # studio  (vault-synced: mac, laptop, pixel)
      age1def...,   # vps-runner      (gitolite CI host)
      age1ghi...    # teammate-personal
```

### Add / remove a device or person
```bash
# 1) edit .sops.yaml recipients
# 2) re-encrypt the data key on EVERY secrets file:
find . -name '*.enc.*' -print0 | xargs -0 -I{} sops updatekeys -y {}
```
`updatekeys` rewrites only the data key (small diff). Removing a recipient is true
revocation ONLY if you also rotate the secret values (they already saw them).

### Rules
- Never transmit a private key over chat/email — vault-sync or gen per-device.
- Keep ≥2 independent recipients always (e.g. personal + vps) so losing one
  device never locks you out.
- Revoke = remove recipient + `updatekeys` + rotate the actual tokens.

---

## 23. Using `pass` (passwordstore.org) as the key holder

`pass` works as the §22 option-2 holder — it's a secret-in/secret-out store,
exactly what `SOPS_AGE_KEY_CMD` needs.

```bash
age-keygen | pass insert -m ci/age-personal     # stores keys.txt; pubkey printed to stderr
pass show ci/age-personal | age-keygen -y        # recover the public key
export SOPS_AGE_KEY_CMD="pass show ci/age-personal"   # per-device; key never on disk
```

### Nuance: `pass` is GPG-backed → root of trust is GPG
`pass` encrypts entries with your GPG key and syncs the encrypted store over git.
So storing the age key in `pass` moves the multi-device problem to **GPG key
distribution**: a new device needs your GPG private key (import per device, or a
**YubiKey/hardware token**). Good property — one master credential, optionally
hardware-bound. Bonus: the `pass` store is a git repo → can be hosted on your own
gitolite (same infra).

### Cleaner alternative: use GPG directly as a sops recipient (skip age for humans)
sops supports PGP recipients natively; mixed recipients are allowed:
```yaml
creation_rules:
  - path_regex: \.enc\.(ya?ml|json|env)$
    pgp: "ABCD1234...FINGERPRINT"     # human(s) via GPG / YubiKey / pass's own key
    age: "age1vps_runner..."          # VPS CI runner (age = simpler headless)
```
- Humans decrypt via GPG (existing key, YubiKey-friendly, multi-device through
  GPG) — no age key to manage.
- VPS runner uses age (no GPG agent/keyring on a headless server).
- sops encrypts the data key to both; either decrypts.

### Android
`pass` has Password Store app + OpenKeychain (GPG on Android) → same GPG key
unlocks both `pass` and PGP-recipient sops. Consistent across all devices.

### Pick
- Stay all-age → `pass` holds the age key (`SOPS_AGE_KEY_CMD`). Works; GPG is the
  hidden root anyway.
- Already on GPG (you are, via `pass`) → use `pgp:` recipients for humans, `age`
  only for the VPS runner. Fewer moving parts. **Recommended for a `pass` user.**

---

## 24. Unattended CI: runner uses age, NOT GPG (passphrase timeouts don't apply)

GPG agent passphrase timeouts are a HUMAN-path problem. The unattended CI path
must never touch GPG — it uses age (no passphrase, no agent, no timeout). This is
the whole reason §23 splits humans (pgp) from the runner (age) into separate
recipients.

```yaml
    pgp: "ABCD...FINGERPRINT"    # humans — interactive; agent timeout is fine (you're there)
    age: "age1vps_runner..."     # runner — passphraseless key file, fully unattended
```
- Human editing → GPG → timeout → re-type. Fine, present.
- CI run → `sops -d` reads the runner's plaintext age key (`~/.config/sops/age/
  keys.txt`, 600) → decrypts → zero interaction, survives reboots.

### Don't force GPG onto the runner
Either strip the passphrase (→ a plaintext key, i.e. an age key with more moving
parts) or hack gpg-agent caching (fragile, breaks on reboot, passphrase still on
the box). Both strictly worse than age. age = GPG-without-the-agent-ceremony for
unattended use.

### Why passphraseless is correct for a server key
A passphrase that must also live on the server to stay unattended protects
nothing — same reason SSH host keys and TLS private keys are passphraseless. The
runner key's real protection: filesystem perms (600, runner-owned, dir 700) +
host hardening (rootless docker, restricted user, §16). The host IS the trust
boundary.

### Optional: TPM-seal the runner key (at-rest encryption, still unattended)
On a Gentoo host with TPM + systemd:
```bash
systemd-creds encrypt --name=age-key keys.txt keys.cred   # TPM-sealed, machine-bound
# runner unit auto-decrypts at run time into tmpfs — no passphrase, useless if copied off-box
```
Best of both (at-rest encryption + unattended). Skip if no TPM / on OpenRC.

---

## 25. Human-gated boot: GPG-unlock → age key in RAM (most paranoid)

Pattern: encrypted age key at rest; human unlocks ONCE per reboot (via GPG/pass)
into a RAM-only folder; age (no agent/timeout) does all CI decrypts until reboot.
GPG gates the boot; age does the unattended work — sidesteps the GPG timeout.

```bash
# unlock-ci  — run once after each reboot (over SSH)
#!/usr/bin/env bash
set -euo pipefail
export GPG_TTY=$(tty)                        # headless: pinentry-tty/curses over SSH
install -d -m700 -o ci -g ci /run/ci-keys
gpg --decrypt /etc/ci/age-key.gpg > /run/ci-keys/age-keys.txt   # or: pass show ci/age-runner >
chown ci:ci /run/ci-keys/age-keys.txt; chmod 600 /run/ci-keys/age-keys.txt
```
Runner env: `SOPS_AGE_KEY_FILE=/run/ci-keys/age-keys.txt`. Decrypt on HOST, inject
values into the container; never mount the RAM key dir into the build container.

### FOOTGUN: swap defeats "RAM-only"
tmpfs (incl. `/run`, `/dev/shm`) CAN be paged to swap → key hits persistent disk,
defeating the premise. Fix one: no swap (often none on a CI VPS) / encrypted swap
(dm-crypt random key) / use `ramfs` (never swaps) / `mlock`. Recommended: dedicated
ramfs for keys:
```
# /etc/fstab
ramfs  /run/ci-keys  ramfs  nodev,nosuid,mode=0700  0 0
```
(ramfs may ignore uid/mode — chown/chmod the dir in unlock-ci.)

### COST: availability — CI down after every reboot until human unlock
Kernel update, crash, power blip → CI halts until someone SSHes in and runs
unlock-ci. Fine/desirable for solo (won't run if unexpectedly rebooted). Musts:
1. Runner fails fast if key file absent → clear error + alert (§10.7), no silent
   outage.
2. Never auto-recreate the key (the human gate is the point).

### Comparison
| Approach | Key at rest | Unattended across reboot | Defends disk-theft/snapshot |
|---|---|---|---|
| §24 plaintext age key file | plaintext (perms+host) | yes, always up | no |
| §25 GPG-unlock → RAM (this) | encrypted | no — human unlock per reboot | yes |
| §24 TPM-seal (systemd-creds) | encrypted, machine-bound | yes, auto-unseal | yes (unless live machine) |

Most paranoid: adds a HUMAN-PRESENCE requirement even TPM lacks (TPM trusts any
boot of the machine; this trusts only a boot you personally unlock). Worth it if
threat model = cloud/snapshot/stolen-disk access and you accept manual re-unlock.
Prefer no babysitting → TPM-seal (§24). Either way: kill swap (or ramfs) or the
RAM premise is a lie; alert on missing key or get silent outages.

---

## 26. NOT DinD — host runner + rootless sibling containers

Explicit, because it's a common assumption. Three models:

| Model | What | Us? |
|---|---|---|
| DinD (docker-in-docker) | a docker daemon nested in a container (`docker:dind`, `--privileged`) | NO |
| DooD (docker-out-of-docker) | a containerized process driving the host daemon via mounted docker.sock | NO |
| Host runner → sibling containers | runner is a HOST process; `docker run` makes siblings on the host daemon | **YES** |

The runner scripts run on the host as the `ci` user (bash, not containerized) and
call `docker run` against the rootless daemon. Build/deploy containers are plain
siblings. No nesting, no daemon-in-a-container, no socket mounted into a container.

**Why not DinD:** needs `--privileged` (= host root), contradicting rootless/§16;
plus overlay-on-overlay storage overhead. DinD/DooD are only needed when the
RUNNER itself is containerized — ours isn't, which is exactly why we sidestep the
whole nested-docker problem.

**The only case nesting could arise:** a `ci/*.sh` that itself runs `docker
build`/`docker run`. Current scope (npm build + wrangler deploy) produces no image
and never does this. Resolving it depends on WHERE the job script runs — two modes:

- **Mode A — containerized job (our default):** `docker run <img> sh -c "ci/*.sh"`.
  The whole script runs INSIDE a container. A `docker build` here IS nested — only
  possible via a mounted socket (DooD) or DinD. Avoid.
- **Mode B — host job:** runner executes `ci/*.sh` directly on the host (as the
  `ci` user, rootless daemon reachable). `docker build` is then a SIBLING, not
  nested — but the job is no longer sandboxed in a container.

For a project that ships an image, pick (best → worst):

| Option | Job sandboxed | Nesting | Note |
|---|---|---|---|
| **Mode A + Buildah/Kaniko** | yes | none | daemonless OCI build in userspace inside the container — no daemon/socket/privilege. **Recommended.** |
| Mode B (host job) | weaker (unpriv host process) | none (sibling) | what GitHub-style runners effectively do |
| Mode A + mounted rootless socket (DooD) | leaky | feels nested | rootless softens it; avoid |
| Mode A + DinD | yes | true nesting | needs privileged — rejected |

The clean answer: keep Mode A and build images with **Buildah/Kaniko** — they have
no daemon to nest, dissolving the problem rather than working around it. (Earlier
drafts said "run docker build as a host-level step" while assuming Mode A — that
was contradictory; host-level build = Mode B = job not containerized.)

---

## 27. Boundary: no job-graph — branching lives in the script

Reaffirms §1 against scope creep (per-job retries + notify raised the question).

- **Notify-on-failure / retries are NOT a DAG.** They're terminal per-job
  behavior (a side-effect + an attempt loop), not job-to-job dependencies. Keep.
- **No `on_success:` / `on_failure:` / `needs:` job fields.** Those create a job
  graph (scheduling, dependents, fan-in, failure propagation) = a DAG = §1's
  explicit non-goal. Do not add.
- **Success/failure BRANCHING belongs inside the job script**, which already has
  full shell power:
  ```sh
  set -e
  if deploy_main; then smoke_test || { rollback; exit 1; }
  else rollback; exit 1; fi
  ```
- **Rule:** runner = trigger → run ONE script per matched job (retries/timeout/
  notify/secrets) → record. Any branching/chaining = inside `ci/*.sh`. A true
  cross-job DAG (first-class job B depends on job A, B has its own dependents) →
  adopt a real engine (§2 Laminar/forge), don't rebuild a scheduler.
- **Test when tempted to add a job dependency:** "can this be two steps in one
  script?" Almost always yes → do that, keep the runner dumb.

### Manifest fields recap (per job)
`on:` (push/create/delete + branches/branches-ignore/paths/paths-ignore),
`image`, `run`, `secrets`, `timeout`, `memory`, `pids`, `network`,
`retries` (clamped to MAX_RETRIES), `retry-delay`, `notify` (on-failure|off).
No dependency/ordering fields — by design.
