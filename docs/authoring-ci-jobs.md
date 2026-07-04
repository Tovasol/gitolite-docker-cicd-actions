# Authoring CI jobs for the `cicd-runner`

A practical, self-contained guide to writing a CI job that runs on the `cicd-runner`. It tells
you what to put in your repo and how to make it run. You do not need to read any framework code.

---

## 1. Mental model (read this first)

- **Archive-push, zero repo access.** The runner never clones or fetches your repo. On every
  push, a git hook snapshots the pushed tree (plus the list of changed files) and hands it to the
  runner. The runner works only from that snapshot.
- **One hardened, throwaway container per job.** Each matched job runs in its own
  `docker run --rm` container, rootless, with `--cap-drop ALL` and
  `--security-opt no-new-privileges`. The container is destroyed when the job exits.
- **Your `run:` script runs INSIDE that container** as `sh -c "<your run: string>"`. The repo
  tree is mounted at `/work`, which is also the working directory.
- **Opt-in.** A repo participates only if it contains `.gitolite/ci.yml` at its root. No file →
  the repo is skipped entirely.
- **Jobs are self-contained.** The image is a stock base image (e.g. `alpine`, `node:...`).
  Nothing repo-specific is pre-installed. If your job needs a tool, install it inside the `run:`
  script (apt / apk / npm / pip / ...). See §8.

---

## 2. The manifest: `.gitolite/ci.yml`

**Exact path:** `.gitolite/ci.yml` at the **root of your repo**. Any other path or name is
invisible to the runner.

It is YAML. The top level is a `jobs:` map; each key under it is a job name.

### 2.1 Field reference

These are the only fields the runner reads. Anything else in the file is ignored (see §10 for two
fields that appear in older examples but do nothing).

Per-job fields under `jobs.<name>`:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `run` | string | *(none — required)* | Shell command run as `sh -c "<run>"` inside the container, cwd `/work`. If empty/missing, the job is skipped. **This is the only required field.** |
| `image` | string | `node:20-alpine` | Docker image to run the job in. |
| `timeout` | int (seconds) | `900` | Wall-clock kill. Exceeding it = status `timeout`. |
| `memory` | docker mem string (e.g. `2g`) | `2g` | `--memory` limit. Enforced only where the host supports cgroup limits (`RESOURCE_LIMITS`, §9); a **no-op** on a host without cgroup-v2/systemd (the OpenRC-rootless target). |
| `pids` | int | `512` | `--pids-limit`. Same conditional enforcement as `memory` (§9). |
| `network` | `bridge` \| `none` | `bridge` | Container network mode. `bridge` = outbound network; `none` = no network. |
| `env` | map of `KEY: value` | *(none)* | Plaintext env vars injected as `-e KEY=value`. They override the built-in `CI_*`/cache vars; a decrypted secret of the same name still wins over them. |
| `on.<event>` | map | *(none)* | Trigger config — see below. The matching event key must be present for the job to fire on that event. |

Trigger sub-fields, under `jobs.<name>.on.<event>` where `<event>` is `push`, `create`, or
`delete`:

| Field | Type | Meaning |
|---|---|---|
| `branches` | list of globs | Include filter. **Empty/omitted = match every branch.** |
| `branches-ignore` | list of globs | Exclude filter. Ignore wins over include. |
| `paths` | list of globs | Path include filter (real pushes only; ignored for manual `ci-job run`). Empty = match all. |
| `paths-ignore` | list of globs | Path exclude filter. |

Events:
- `push` — commits pushed to an existing branch.
- `create` — a branch first appears (its first push). A brand-new branch fires `create`, **not**
  `push`. To run CI on a new branch, give the job an `on.create` trigger too (or use `ci-job run`).
- `delete` — a branch is deleted → runs as a *teardown* job. A job is a teardown job only if it
  has an `on.delete` key.

**Glob semantics** (GitHub-Actions-style): `*` matches within one path/branch segment (not `/`),
`**` matches across `/`, `?` matches one non-`/` char. Lists may be YAML arrays or comma/space
separated.

### 2.2 Branch-filter rules

For a given event:
1. If `branches-ignore` is set and matches the branch → **no run**.
2. Else if `branches` is empty/omitted → **run** (match-all).
3. Else → run only if the branch matches `branches`.

But the job only reaches those rules if the `on.<event>` key exists at all:
- `on: { push: { branches: [main] } }` → runs on push to `main` only.
- `on: { push: {} }` → `push` present, `branches` empty → runs on **every** push to any branch.
- A job with no `on.push` → never runs on a push, regardless of branch.

### 2.3 Minimal example

```yaml
jobs:
  hello:
    on: { push: { branches: [main] } }
    image: alpine
    run: echo hello world
```

### 2.4 Annotated example

```yaml
jobs:
  test:
    on:
      push:
        branches: [main]            # only main
        branches-ignore: ["wip/**"] # ...but never wip/* branches
        paths:                      # ...and only if these files changed
          - "src/**"
          - ".gitolite/ci.yml"
        paths-ignore: ["**/*.md"]   # ...excluding markdown-only changes
    image: node:lts-bookworm-slim   # bash + node available
    timeout: 600                    # 10 min wall-clock kill
    network: bridge                 # needs outbound (npm install)
    env:
      NODE_ENV: test                # plaintext env var -> -e NODE_ENV=test
    run: sh ci/test.sh              # your script, committed in the repo
```

---

## 3. Copy-paste "hello world" (guaranteed green)

Commit this as `.gitolite/ci.yml` at your repo root, then push to your default branch (`main`).
Stock `alpine` image, no secrets, no deps, no network:

```yaml
jobs:
  hello:
    on: { push: { branches: [main] } }
    image: alpine
    run: echo hello world
```

- `image: alpine` is a stock image; `echo` is built in — no installs, no network.
- `run` exits 0 → run status `exit:0`.
- If your default branch is not `main`, change `[main]` to your branch name, or use
  `on: { push: {} }` to run on every branch.
- A brand-new branch's first push is a `create` event, not `push`. For that case use
  `on: { push: { branches: [main] }, create: { branches: [main] } }`, or trigger manually with
  `ci-job run` (§11).

Verify it went green with `ci-job` (§11).

---

## 4. Common patterns

Copy-paste starting points for the usual jobs. All fields are from §2; the scripts they call are
ones you commit in your repo. Helpers (`step`, `retry`, `notify_*`, `die`) come from `/cicd/lib.sh`
(§5); the dependency cache under `/cache` is automatic (§7).

> For whole, ready-to-save files (a full multi-job `.gitolite/ci.yml`, `.sops.yaml`, and a complete
> `ci/secrets.example.yaml`), see **§15** — no assembly from snippets.

### 4.1 Lint / test on every push to main

Runs a committed script that installs its own tools and runs your tests.

```yaml
# .gitolite/ci.yml
jobs:
  test:
    on: { push: { branches: [main] } }
    image: node:lts-bookworm-slim    # ships bash; run: still starts as sh, so call bash explicitly
    network: bridge                  # needed to install deps
    run: bash ci/test.sh
```

```sh
# ci/test.sh  (committed in your repo)
#!/usr/bin/env bash
set -eu
. /cicd/lib.sh

step "install tools"
retry -n 3 -d 5 -- apt-get update -qq
apt-get install -y -qq --no-install-recommends shellcheck

step "run tests"
npm ci            # cached automatically under /cache
npm test
```

### 4.2 Build + deploy, gated on a path, using secrets

Only runs when files under `site/` change on `main`. Reads credentials from your encrypted
secrets (§8.3) as env vars, and reports success/failure by email + any other configured channel.

```yaml
# .gitolite/ci.yml
jobs:
  deploy-site:
    on:
      push:
        branches: [main]
        paths: ["site/**"]
    image: node:20-alpine
    timeout: 900
    network: bridge
    run: sh ci/deploy-site.sh
```

```sh
# ci/deploy-site.sh
#!/bin/sh
set -eu
. /cicd/lib.sh

step "build"
npm ci && npm run build

step "deploy"
# CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID come from ci/secrets.<env>.enc.yaml (§8.3)
if npx wrangler pages deploy ./dist --project-name my-site; then
  notify_success "deployed $CI_BRANCH @ $CI_SHA"
else
  die "deploy failed for $CI_BRANCH @ $CI_SHA"
fi
```

### 4.3 Preview environments: create + push, with teardown on delete

A per-branch preview env for every `feat/*` branch. Names its resources off `CI_BRANCH_SLUG`
(DNS-safe), so create and update are idempotent. A second job tears it down when the branch is
deleted.

```yaml
# .gitolite/ci.yml
jobs:
  preview:
    on:
      create: { branches: ["feat/*", "exp/*"] }   # first appearance of the branch
      push:   { branches: ["feat/*", "exp/*"], paths: ["site/**"] }
    image: node:20-alpine
    run: sh ci/preview-deploy.sh      # create-or-update; resource name = preview-$CI_BRANCH_SLUG

  preview-teardown:
    on:
      delete: { branches: ["feat/*", "exp/*"] }    # branch deleted -> teardown job
    image: node:20-alpine
    run: sh ci/preview-teardown.sh    # delete the resource named preview-$CI_BRANCH_SLUG
```

In the scripts, build the resource name once and reuse it:

```sh
# ci/preview-deploy.sh (and mirror in preview-teardown.sh)
#!/bin/sh
set -eu
. /cicd/lib.sh
NAME="preview-$CI_BRANCH_SLUG"
step "deploy $NAME"
npx wrangler pages deploy ./dist --project-name "$NAME" || die "preview deploy failed"
notify_success "preview up: https://$NAME.example.com"
```

### 4.4 Dependency install that uses the cache

No wiring needed — the common package managers already point at `/cache`, so installs are reused
across runs.

```yaml
jobs:
  build:
    on: { push: { branches: [main] } }
    image: python:3.12-slim
    network: bridge
    run: |
      pip install -r requirements.txt   # cached under /cache/pip automatically
      python -m build
```

### 4.5 Retry + notify inside a script

`retry` re-runs a single flaky command; `notify`/`notify_success`/`notify_error`/`die` report
status. None of these are manifest fields — they are helper functions you call.

```sh
#!/bin/sh
set -eu
. /cicd/lib.sh

notify "starting build for $CI_BRANCH"
retry -n 3 -d 10 -- npm ci          # retry transient network failures
npm run build || die "build failed"
notify_success "build ok for $CI_SHA"
```

---

## 5. Helper library: `/cicd/lib.sh`

Mounted read-only at **`/cicd/lib.sh`** in every container. POSIX sh (works in busybox `ash`).
Source it at the top of your `run:` script:

```sh
. /cicd/lib.sh
```

Functions you call:

| Function | Signature | Use |
|---|---|---|
| `step` | `step <name...>` | Print a `=== name ===` stage marker into the run's log. |
| `retry` | `retry [-n tries] [-d delay] -- <cmd...>` | Retry one command (default 3 tries, 10 s apart). Retries the single command, not the whole job. e.g. `retry -n 3 -d 5 -- apt-get update`. |
| `wait_all` | `wait_all <pid>...` | Wait on background pids; returns 1 if any failed. |
| `die` | `die <message...>` | Emit a failure notification, print `FATAL: <message>`, and `exit 1`. |
| `notify` | `notify <message...>` | Informational notification. |
| `notify_success` | `notify_success <message...>` | Terminal success notification (`[CI OK]`). |
| `notify_error` | `notify_error <message...>` | Terminal failure notification (`[CI FAIL]`). |

How notifications work: `notify*` do **not** send anything from inside the container — they record
the message, and the runner delivers it after the container exits. So they work in any image, need
no curl/credentials/network in the job, and still fire if the job is OOM- or timeout-killed. A job
that exits non-zero without emitting a terminal notification still triggers a failure alert.

> **Want emails (SMTP)?** Emitting notifications is one half; *delivery* (email and how it's sent)
> is the other. A repo can ship its own SMTP credentials in the tier's encrypted secrets
> (`ci/secrets.<env>.enc.yaml`) so alerts go to *your* mailbox. See **§13** for the full picture and
> the exact secret keys (e.g. `SMTP_HOST_ADDR`, `SMTP_USER_PWD`, `NOTIFY_TO`).

---

## 6. Environment available inside the job

Injected env vars:

| Var | Meaning |
|---|---|
| `CI_EVENT` | `push`, `create`, or `delete` (a manual `ci-job run` reports as `push`). |
| `CI_REPO` | Repo name (e.g. `tovasol/agent-forge`). |
| `CI_BRANCH` | The exact branch name. |
| `CI_BRANCH_SLUG` | DNS-safe slug of the branch (lowercased, non-alnum → `-`, + 6-char hash). Use it to name external resources (preview envs, etc.). |
| `CI_SHA` | The commit sha being built. (Not set on `delete`/teardown — there is no new tree.) |
| `CI_PUSHER` | The user who triggered it. |
| `CI_CACHE_DIR` | `/cache` (the shared cache mount, §7). |
| `CI_ENV_DIR` | `/envstate` — a persistent per-(repo,branch) state dir, for preview-env bookkeeping/teardown. |
| `CI_OUTBOX` | `/cicd/out/notify` — the notify outbox (used by the helpers; you don't write it directly). |
| Cache vars | Many package-manager cache vars are pre-pointed into `/cache` (§7). |
| Secret vars | If you ship `ci/secrets.<env>.enc.yaml` (per-env; legacy `ci/secrets.enc.yaml` still ok), each decrypted key of the resolved tier appears as an env var (§8.3). |
| `env:` vars | Any `jobs.<name>.env` map entries. |

Filesystem:
- **`/work`** — the repo tree, and the working directory of your `run:` command. So `sh ci/test.sh`
  resolves to `/work/ci/test.sh`, and relative paths work.
- **`/cache`** — a single global cache shared across all repos and runs. Writable. Persisted
  between runs; age- and size-capped.
- **`/envstate`** — small persistent per-branch state dir.
- **`/cicd/lib.sh`** — the helper library (read-only).
- **`/cicd/out`** — the notify outbox dir (written via the helpers).

---

## 7. The dependency cache (`/cache`)

The runner points every common package manager at `/cache`, so dependency installs are cached
across runs automatically — no per-repo wiring:

```
CI_CACHE_DIR=/cache  XDG_CACHE_HOME=/cache/xdg
npm_config_cache=/cache/npm  YARN_CACHE_FOLDER=/cache/yarn  pnpm_config_store_dir=/cache/pnpm/store
PIP_CACHE_DIR=/cache/pip  POETRY_CACHE_DIR=/cache/poetry  UV_CACHE_DIR=/cache/uv
GOMODCACHE=/cache/go/mod  GOCACHE=/cache/go/build  CARGO_HOME=/cache/cargo
COMPOSER_CACHE_DIR=/cache/composer  NUGET_PACKAGES=/cache/nuget
GRADLE_USER_HOME=/cache/gradle  MAVEN_ARGS=-Dmaven.repo.local=/cache/maven
BUNDLE_PATH=/cache/bundle  DENO_DIR=/cache/deno  MIX_HOME=/cache/mix  HEX_HOME=/cache/hex
```

(The complete list is in §14c.) If your tool isn't listed, point it at `$XDG_CACHE_HOME`
(`/cache/xdg`) or `$CI_CACHE_DIR` (`/cache`) yourself. `apt` archives are not cached (§8.1).

---

## 8. Self-contained jobs: installing your own dependencies

Nothing repo-specific is pre-installed. Install what you need inside the `run:` script.

### 8.1 apt (Debian/Ubuntu images) — works out of the box

`apt-get install` works in the hardened container with no workaround. Just:

```sh
. /cicd/lib.sh
retry -n 3 -d 5 -- apt-get update -qq
apt-get install -y -qq --no-install-recommends curl unzip ca-certificates
```

(apt's downloaded `.deb`s are not cached across runs; the expensive caches — npm/pip/cargo/go/
maven/... — already persist on `/cache`, §7.)

### 8.2 Other package managers

apk (alpine), npm/pnpm/yarn, pip/poetry/uv, cargo, go, etc. all work and are cached via `/cache`
automatically. Example (alpine):

```sh
apk add --no-cache curl jq
```

Install your repo's build dependencies in the job container with apt/apk/npm/etc. as shown.

### 8.3 Secrets (sops + age) — per-environment

Secrets are sops-encrypted files committed **in your repo** (ciphertext only — never plaintext).
The runner resolves an **environment** from the (gitolite-gated, trusted) branch, decrypts **only
that tier's** file with **only that tier's key**, and injects each key as an env var into your job
container. There is **no `secrets:` manifest field**; the runner keys off the *presence* of the
encrypted files (see §10). Full model + operator key management: **`docs/per-env-secrets.md`**.

#### Where the files go (exact paths)

```
<repo root>/
├── .sops.yaml                    # sops recipients per tier (who may decrypt). REQUIRED to encrypt.
└── ci/
    ├── secrets.dev.enc.yaml      # dev-tier secrets   (decrypted for env "dev")
    ├── secrets.qa.enc.yaml       # qa-tier secrets    (env "qa")
    ├── secrets.prod.enc.yaml     # prod-tier secrets  (env "prod")
    └── secrets.example.yaml      # optional plaintext TEMPLATE for humans (never the real secret)
```

The runner reads **`ci/secrets.<env>.enc.yaml`** for the resolved env. A **legacy single
`ci/secrets.enc.yaml`** is still supported for repos that don't need tiers — but if ANY
`ci/secrets.*.enc.yaml` exists, the per-env files are authoritative (a run whose env has no
matching file is **refused**, never silently handed the legacy blob).

#### Which env? (branch → env)

- Default: **env = the sanitized branch name** (`dev`→`dev`, `prod`→`prod`, `feat/x`→`feat-x`).
- The operator may alias branches → envs host-side (`environments.map`) — e.g. `main`→`prod`. The
  binding lives on the host, **never in your pushed tree**, so you can't claim another tier.
- A job may optionally declare `jobs.<name>.environment: <env>` for readability; it must **equal**
  the branch-resolved env or the job is refused.

#### Step 1 — `.sops.yaml` at the repo root (per-tier recipients)

Each tier file is encrypted to **its own** runner age key (there is **no shared master key**), plus
your GPG key for editing. Human read/edit access narrows as you climb tiers. Get each tier's runner
age public key + confirm your GPG fingerprint from your operator:

```yaml
# Per-tier recipients. Runner: one age key PER TIER (dev/qa/prod). Humans: GPG, tiered.
creation_rules:
  - path_regex: (^|/)secrets\.prod\.enc\.ya?ml$
    key_groups: [{ age: ["age1PROD_RUNNER"], pgp: ["YOUR_GPG_FPR"] }]
  - path_regex: (^|/)secrets\.qa\.enc\.ya?ml$
    key_groups: [{ age: ["age1QA_RUNNER"],   pgp: ["YOUR_GPG_FPR"] }]
  - path_regex: (^|/)secrets\.dev\.enc\.ya?ml$
    key_groups: [{ age: ["age1DEV_RUNNER"],  pgp: ["YOUR_GPG_FPR"] }]
```

#### Step 2 — write, encrypt, commit each tier file

Each top-level key becomes an **env var** inside your job (flat `key: value`, scalars only). `sops`
routes each file to the right recipients by name via `.sops.yaml`, so you edit plaintext, it saves
ciphertext:

```sh
sops ci/secrets.dev.enc.yaml                          # opens $EDITOR; on save writes ENCRYPTED
sops ci/secrets.qa.enc.yaml
sops ci/secrets.prod.enc.yaml
grep -L sops: ci/secrets.*.enc.yaml || echo "all encrypted ✓"   # none listed = all ciphertext
git add ci/secrets.*.enc.yaml && git commit && git push          # ciphertext only
```

> **For the full copy-paste template that documents *every* key** — deploy creds, the complete
> email/SMTP block, arbitrary build secrets — see **§15.3**.

#### Behavior

- **Trigger = file presence.** Any `ci/secrets.*.enc.yaml` (or legacy `secrets.enc.yaml`) → the
  runner decrypts the resolved tier + injects. No manifest field opts in.
- **Only the resolved tier is decrypted, with only that tier's key.** A higher tier's file sits in
  `/work` as ciphertext the job can't read — and because tier selection is enforced by the **key**
  (not the filename), copying/symlinking another tier's ciphertext under this tier's name still
  **fails to decrypt** (the loaded key isn't a recipient). A planted decrypt-input symlink is refused.
- **Each key → one env var** in the `run:` script's environment.
- **Key not loaded → deferred, not failed.** If the resolved tier's key isn't unlocked on the host,
  the run is held pending and auto-runs once the operator unlocks it.
- **No tier for this env → refused** (status `secrets-decrypt-failed`) when per-env files exist but
  none matches — never a silent fallback to another tier.
- **Decrypt failure → status `secrets-decrypt-failed`** (e.g. encrypted to the wrong recipient —
  re-run `sops updatekeys ci/secrets.<env>.enc.yaml`).
- Decrypted values exist only for the container's lifetime; the age keys never enter the container.

> **Whoever can push a tier's branch can read that tier's secrets** (they run its jobs). So scope
> every credential to its tier — and never put a personal-identity credential (a Gmail app-password,
> your API key) in a tier that others can push. See §13 for the notification consequence.

---

## 9. Constraints you MUST respect

- **Hardened rootless container.** `--cap-drop ALL` and `--security-opt no-new-privileges`. No
  mounting, no raw sockets, no setuid/`sudo`-up, no `setcap`, no changing kernel params.
- **No Docker-in-Docker / no docker access.** Jobs cannot run `docker`, build images, or reach a
  docker socket. There is no docker binary or socket in the container.
- **Jobs must be self-contained.** Assume only what the base image ships. Install your own deps
  (§8).
- **`memory`/`pids` are enforced only where the host supports cgroup limits.** `RESOURCE_LIMITS=auto`
  (default) applies `--memory`/`--pids-limit` on a cgroup-v2/systemd host, else falls back to POSIX
  ulimits (`nproc`/`fsize`). On the OpenRC-rootless target they're a **no-op** — don't rely on them
  there. `timeout`, `network`, and the cap/no-new-privileges hardening always apply.
- **Network modes:** `bridge` (outbound) or `none`. Default `bridge`. Use `none` for offline jobs.
- **Path filters apply to real pushes only.** A manual `ci-job run` skips path filters (and
  `ci-job run --job <name>` skips branch *and* path filters).
- **Secrets need sops/age** and an operator-loaded key (§8.3).
- **`run:` is `sh -c`.** It runs in `sh`, not bash. For bash, use an image that ships bash and
  invoke `bash yourscript.sh`, or keep the `run:` string POSIX.

---

## 10. Two fields that look real but are IGNORED

Older example manifests show fields the runner does **not** read. Don't rely on them:
- **`version:`** — appears at the top of examples; it does nothing.
- **`secrets: [ ... ]`** — appears under jobs in some examples; it has no effect. Secrets are
  driven entirely by the presence of the per-env `ci/secrets.<env>.enc.yaml` files (legacy single
  `ci/secrets.enc.yaml` still honored) (§8.3).

---

## 11. Trigger and observe a run

Normal flow: just `git push`; CI triggers automatically if `.gitolite/ci.yml` is present. To
trigger manually or to watch/inspect, use the `ci-job` command over ssh (scoped to repos your ssh
key may access):

```sh
# Trigger a run and stream its status until terminal:
ssh git@<host> ci-job run <repo> <branch> --watch

# Trigger just one job (skips branch + path filters):
ssh git@<host> ci-job run <repo> <branch> --job hello --watch

# Trigger an exact commit instead of the branch tip:
ssh git@<host> ci-job run <repo> <branch> --ref <sha> --watch

# Health + per-job rollups + recent runs (scope optional):
ssh git@<host> ci-job status <repo>

# Show / follow a run's log:
ssh git@<host> ci-job log <repo> <branch>          # newest run for the branch
ssh git@<host> ci-job log <repo> hello             # newest run of job "hello"
ssh git@<host> ci-job log <repo> hello -f          # follow live
```

What "green" means:
- `ci-job run ... --watch` prints status transitions, e.g. `queued → running → exit:0`.
  **`exit:0` = green.** `exit:N` (N≠0), `timeout`, or `secrets-decrypt-failed` = red.
- If `--watch` reports the run as *deferred* (not started; queued), docker is down or a needed age
  key isn't loaded — run `ci-job status` to check. Not a failure of your job.
- `--watch` follows *status*; to read the actual output use `ci-job log ... -f`.

(`run` requires WRITE access to the repo; `status`/`log` require READ. Access is enforced by
gitolite against your ssh key.)

---

## 12. Common mistakes checklist

- [ ] **Wrong manifest path.** Must be exactly `.gitolite/ci.yml` at the repo root, and committed.
      No file → nothing happens (silent).
- [ ] **Assuming tools are pre-installed.** They are not. Install deps in `run:` (§8).
- [ ] **Expecting docker.** No DinD, no docker socket — jobs cannot build/run containers.
- [ ] **Wrong branch filter.** Omitting `on.<event>` means the job never fires on that event; an
      empty `branches:` means *all* branches (not none). See §2.2.
- [ ] **First push to a new branch.** That's a `create` event, not `push`. Add `on.create` or use
      `ci-job run`.
- [ ] **`run:` is `sh`, not bash.** Use a bash image + `bash script.sh` if you need bash.
- [ ] **Counting on `memory`/`pids` limits.** Enforced only with cgroup support (`RESOURCE_LIMITS`); a no-op on the OpenRC-rootless host.
- [ ] **Using a `secrets:` or `version:` field.** Ignored. Secrets = presence of the per-env
      `ci/secrets.<env>.enc.yaml` files (legacy single `ci/secrets.enc.yaml` still honored).
- [ ] **Privileged operations.** `cap-drop ALL` + `no-new-privileges` forbid mounting, setcap,
      sudo-up, raw sockets, etc.
- [ ] **Relying on path filters via manual run.** `ci-job run` skips path filters.

---

## 13. Notifications & email (SMTP)

Notifications are **opt-in per repo (per tier)**: you **emit** them from your job into the outbox;
the **runner delivers** them host-side after the job, using the **resolved tier's** decrypted SMTP
creds (`ci/secrets.<env>.enc.yaml`). A repo/env that sets no SMTP creds simply **doesn't notify** —
there is no required host fallback. Give a tier email creds and its alerts go to your mailbox.

```
 YOU (in your repo, per tier)                  RUNNER (host-side, AFTER the job)
 ────────────────────────────                  ─────────────────────────────────
 emit into the outbox                          deliver with the TIER's decrypted creds
   . /cicd/lib.sh                                reads ci/secrets.<env>.enc.yaml SMTP keys
   notify "deploy starting"                      (per §13.3) — no creds set → no email
   notify_success "deployed ok"                  crash-proof BACKSTOP even if the job
   notify_error  "deploy failed"                 was OOM/timeout-killed and wrote nothing
   die "fatal"                                  optional host last-resort: /etc/cicd-runner/notify.env
```

- **You** only call the `/cicd/lib.sh` helpers (`notify`, `notify_success`, `notify_error`, `die`)
  from §5. Nothing is sent from inside your container — the helpers write to the outbox.
- **After the container exits**, the runner delivers each queued notification host-side using the
  resolved tier's decrypted creds, plus a **backstop** alert if the job failed and emitted no
  terminal `notify_success`/`notify_error`. This path is **crash-proof**: the backstop fires even
  when the job is OOM/SIGKILL/timeout-killed and wrote nothing to the outbox.
- **A direct `curl` from inside the job is unreliable on crash** — a killed job never reaches it.
  Use the `notify_*`/`die` outbox for anything you must not miss; keep direct calls for best-effort
  extras only.
- **Scope creds per tier.** Whoever can push a tier's branch runs its jobs and can read that tier's
  secrets. **Never** put a personal-identity credential (a Gmail app-password, your personal API
  key) in a tier others can push — its leak lets them *impersonate you*. A personal-identity SMTP
  login is acceptable **only** in a tier restricted to one person (e.g. `prod`, where gitolite
  `@prod` = you). For a **shared** tier, use a **send-only provider key** (SES `ses:SendEmail`, a
  Postmark server/send token, Resend) whose leak = "send as the CI bot", not "impersonate a human".

### 13.1 Delivery handlers

The operator picks the handler by setting `NOTIFY_CMD` (it has no code-level default — if unset,
nothing is delivered). Two handlers ship with the runner; the shipped `runner.conf.sample` points
`NOTIFY_CMD` at the email one:

| Handler | What it does |
|---|---|
| `notify-email` | Emails the alert over SMTP. The handler the shipped config selects. |
| `notify-wall` | Broadcasts to logged-in terminals. |

The email handler emails **terminal** events by default — `notify_success` (`[CI OK]`),
`notify_error`/`die` (`[CI FAIL]`), and the failure backstop. Plain `notify` (info) is **not**
mailed unless `NOTIFY_INFO=1` is set (§13.4).

### 13.2 SMTP credentials in `ci/secrets.<env>.enc.yaml` — per tier, opt-in

The email handler reads SMTP config from **the resolved tier's decrypted secrets first**, then, only
if a key is still unset, from an **optional** operator-global file (`/etc/cicd-runner/notify.env`).
The reliable, recommended path for multi-repo is to put each repo's own creds in **its tier's**
secrets — no host file needed, no manifest field, no operator change (as long as the operator left
the shipped email handler in place). Each variable resolves independently: supply only `NOTIFY_TO`
and inherit the (optional) host SMTP server, or supply everything. **Set nothing → the tier simply
doesn't notify** (`notify-email` no-ops silently).

> The handler runs host-side, so it uses the *decrypted* tier secrets at delivery time — which means
> that tier's age key must be loaded (the same per-tier key that gates its secret-using jobs, §8.3).
> These credentials are read at delivery time; they are not exposed to your job's env unless you
> also reference them in `run:`. Because delivery is host-side and post-job, it survives a job
> crash (the crash-proof backstop, §13) — unlike a `curl` from inside a killed container.

### 13.3 SMTP / email variable reference

These go in the resolved tier's **`ci/secrets.<env>.enc.yaml`** (per-repo, recommended) and/or the
**optional** **`/etc/cicd-runner/notify.env`** (operator-global last resort). The primary names match
**Plausible CE**'s SMTP config so you can reuse the same values; a generic alias is accepted for each
(the primary is tried first, then the alias):

| Primary key | Alias | Default (if unset) | Meaning |
|---|---|---|---|
| `SMTP_HOST_ADDR` | `SMTP_HOST` | `smtp.gmail.com` | SMTP server hostname. |
| `SMTP_HOST_PORT` | `SMTP_PORT` | `587` | SMTP port. **Port `465` ⇒ implicit TLS; any other port (587/25) ⇒ STARTTLS** — chosen from the port, no separate TLS flag. |
| `SMTP_USER_NAME` | `SMTP_USER` | *(none)* | SMTP/auth username. **Required** — if empty, no email is sent. |
| `SMTP_USER_PWD` | `SMTP_PASS` | *(none)* | SMTP/auth password (for Gmail, a 16-char App Password). **Required.** |
| `MAILER_EMAIL` | — | falls back to `SMTP_USER_NAME` | The `From:` address; also the default recipient if `NOTIFY_TO` is unset. |
| `NOTIFY_TO` | `MAILER_EMAIL` | falls back to `SMTP_USER_NAME` | Recipient(s). Comma-separated accepted. **Required** (directly or via fallback). |
| `NOTIFY_FROM` | — | falls back to `MAILER_EMAIL`/`SMTP_USER_NAME` | Alternative `From:` source. |
| `SMTP_FROM_NAME` | `NOTIFY_FROM_NAME` | `cicd-runner` | `From:` display name. |

Authentication is always used. A username, password, and a recipient must all resolve, or no email
is sent (this never fails the job). Minimum to get mail from a per-repo secrets file:
`SMTP_USER_NAME`, `SMTP_USER_PWD`, and either `NOTIFY_TO` or `MAILER_EMAIL`.

### 13.4 Presentation / behavior knobs (same two locations, optional)

| Key | Default | Meaning |
|---|---|---|
| `NOTIFY_INFO` | `0` | `1` = also email non-terminal `notify` (info) notices, not just success/fail. |
| `NOTIFY_LOGLINES` | `30` | How many trailing lines of the run's log to include in the body. |
| `NOTIFY_SUBJECT` | `{{TAG}} {{REPO}}/{{BRANCH}} {{JOB}} — {{STATUS}}` | Custom subject template. |
| `NOTIFY_BODY` | *(built-in block)* | Custom body template. In the YAML secrets file you can use a multi-line block scalar; in the flat `notify.env` file it must be single-line. |

Template tokens (literal `{{...}}` substitution; message/log are treated as untrusted text):
`{{STATUS}}` `{{TAG}}` `{{REPO}}` `{{BRANCH}}` `{{JOB}}` `{{EVENT}}` `{{SHA}}` `{{SHORT_SHA}}`
`{{PUSHER}}` `{{MESSAGE}}` `{{LABEL}}` `{{HOST}}` `{{NOW}}` `{{LOGTAIL}}`.

### 13.5 Checklist for "email me on CI failure"

1. Keep `notify_error`/`die` (or rely on the failure backstop) in your `run:` script — §5.
2. Add SMTP keys to the tier's `ci/secrets.<env>.enc.yaml` — put them in **each tier** you want mail
   from, e.g.:
   ```yaml
   SMTP_HOST_ADDR: smtp.gmail.com
   SMTP_HOST_PORT: "587"
   SMTP_USER_NAME: you@gmail.com
   SMTP_USER_PWD: your-16-char-app-password
   NOTIFY_TO: alerts@example.com        # comma-separated for several
   # optional:
   # SMTP_FROM_NAME: my-project-ci
   # NOTIFY_LOGLINES: "50"
   ```
   (sops-encrypt against that tier's age recipient — §8.3.) Quote numeric values so they stay
   strings. **Credential scope:** a personal-identity login like the Gmail app-password above is
   safe **only** in a tier restricted to you (e.g. `prod`). In any tier others can push, use a
   send-only provider key (SES/Postmark/Resend) instead, or omit email for that tier.
3. That's it — the shipped email handler picks these up per tier. You do not edit any host config.
   If the operator changed the default handler, ask them.

---

## 14. Configuration & environment reference (full surface)

Everything the framework reads, grouped by **who sets it** and **where**. Items marked **operator
config** are listed so you know the feature exists; you cannot set them as a job author.

### (a) Job author — in the manifest `.gitolite/ci.yml`

Fully covered in §2: per-job `run`, `image`, `timeout`, `memory`, `pids`, `network`, `env`, and
`on.<push|create|delete>` with `branches`, `branches-ignore`, `paths`, `paths-ignore`. Anything
else is ignored (`version:`, `secrets:` — §10).

### (b) Job author / repo — conventional files in your repo

| Path | Purpose |
|---|---|
| `.gitolite/ci.yml` | The manifest. Its presence is the opt-in gate (§2). |
| `ci/secrets.<env>.enc.yaml` | Per-env encrypted secrets → the resolved tier's file is decrypted and injected as env vars; also the source of that tier's SMTP creds (§13.2). Presence of any `secrets.*.enc.yaml` is the secrets trigger (legacy single `ci/secrets.enc.yaml` still honored); there is no `secrets:` field. |

There are no other magic repo paths. (`ci/*.sh` scripts only matter because *your* `run:` calls
them.)

### (c) Inside-container environment your job receives

**CI_* identity/context vars:**

| Var | Value / meaning |
|---|---|
| `CI_EVENT` | `push`, `create`, or `delete` (manual `ci-job run` reports as `push`). |
| `CI_REPO` | Repo path, e.g. `tovasol/agent-forge`. |
| `CI_BRANCH` | Exact branch name. |
| `CI_BRANCH_SLUG` | DNS-safe slug (lowercased, non-alnum→`-`, +6-char hash). |
| `CI_SHA` | Commit sha being built. (Not set on `delete`/teardown.) |
| `CI_PUSHER` | User who triggered it. |
| `CI_CACHE_DIR` | `/cache` — the shared cache mount (§7). |
| `CI_ENV_DIR` | `/envstate` — persistent per-(repo,branch) state dir. |
| `CI_OUTBOX` | `/cicd/out/notify` — notify outbox (don't write it directly). |

**Cache vars (complete — each points a package manager at `/cache`):**

| Var | Value | Ecosystem |
|---|---|---|
| `CI_CACHE_DIR` | `/cache` | generic / this runner |
| `XDG_CACHE_HOME` | `/cache/xdg` | XDG fallback (use for unlisted tools) |
| `XDG_DATA_HOME` | `/cache/xdg-data` | XDG data |
| `npm_config_cache` | `/cache/npm` | npm |
| `YARN_CACHE_FOLDER` | `/cache/yarn` | yarn |
| `pnpm_config_store_dir` | `/cache/pnpm/store` | pnpm store |
| `pnpm_config_cache_dir` | `/cache/pnpm/cache` | pnpm cache |
| `BUN_INSTALL_CACHE_DIR` | `/cache/bun` | bun |
| `PIP_CACHE_DIR` | `/cache/pip` | pip |
| `POETRY_CACHE_DIR` | `/cache/poetry` | poetry |
| `UV_CACHE_DIR` | `/cache/uv` | uv |
| `PIPENV_CACHE_DIR` | `/cache/pipenv` | pipenv |
| `COMPOSER_CACHE_DIR` | `/cache/composer` | PHP composer |
| `GOMODCACHE` | `/cache/go/mod` | Go modules |
| `GOCACHE` | `/cache/go/build` | Go build |
| `CARGO_HOME` | `/cache/cargo` | Rust cargo |
| `BUNDLE_PATH` | `/cache/bundle` | Ruby bundler (gems) |
| `BUNDLE_USER_CACHE` | `/cache/bundle/cache` | Ruby bundler cache |
| `NUGET_PACKAGES` | `/cache/nuget` | .NET NuGet |
| `GRADLE_USER_HOME` | `/cache/gradle` | Gradle |
| `MAVEN_ARGS` | `-Dmaven.repo.local=/cache/maven` | Maven (an arg, not a dir var) |
| `DENO_DIR` | `/cache/deno` | Deno |
| `MIX_HOME` | `/cache/mix` | Elixir mix |
| `HEX_HOME` | `/cache/hex` | Elixir hex |

**Layering (later wins):** your `jobs.<name>.env` map overrides the `CI_*`/cache defaults; a
decrypted secret of the same name overrides an `env:` entry.

### (d) Operator / host config — `runner.conf`

Set by the operator in `runner.conf`. **Not author-settable** — listed so you know the surface and
its defaults. "Affects authors?" flags what changes your jobs' behavior or limits.

**Identity / paths:**

| Key | Default | Controls | Affects authors? |
|---|---|---|---|
| `RUNNER_USER` | `cicd-runner` | Unix user the runner/containers run as. | Indirectly. |
| `RUNNER_BASE` | `/home/cicd-runner/runner` | Root of the runner's working dirs. | No. |
| `GIT_REPO_BASE` | `/home/git/repositories` | Documented location of bare repos. **Declared but has no effect today.** | No. |
| `LOCAL_BIN` | `/home/cicd-runner/.local/bin` | Dir added to `PATH` so the runner finds its tools. | No. |

**Secrets (sops + age):**

| Key | Default | Controls | Affects authors? |
|---|---|---|---|
| `AGE_KEY_DIR` | `/run/ci-keys` | Ramfs dir holding one decrypted **per-tier** private key at `<env>.age`. Presence of the resolved tier's key gates that tier's secret-using jobs and its email delivery. | Yes — if that tier's key is unloaded, its secret jobs **defer** and its SMTP creds can't be read. |
| `AGE_ENVS` | *(unset)* | Space-separated list of tiers the runner knows (e.g. `"dev qa prod"`). | Indirectly — an env not listed has no key slot. |
| `AGE_RECIPIENT_<env>` | *(unset)* | The PUBLIC age recipient of each tier's key; `unlock-ci` routes a piped key to `<env>.age` by matching its derived pubkey here. | No (operator wiring). |
| `AGE_LEGACY_RECIPIENT` | *(unset)* | Optional PUBLIC recipient for the legacy single `secrets.enc.yaml`; a piped key matching it goes to `SOPS_AGE_KEY_FILE`. | No. |
| `SOPS_AGE_KEY_FILE` | `/run/ci-keys/age-keys.txt` | **LEGACY single-key slot** — the decrypted key used only for the legacy `ci/secrets.enc.yaml` path. Per-tier files use `AGE_KEY_DIR/<env>.age` instead. | Yes — for legacy-secrets repos, if unloaded those jobs **defer**. |
| `SHM_DIR` | `/dev/shm` | tmpfs where decrypted env-files are written transiently. | No. |
| `CICD_ENV_MAP` | `$RUNNER_BASE/etc/environments.map` | Host-side branch→env map (first match wins) used to resolve the secrets tier; no map → env = sanitized branch name. Operator-owned; the pushed tree can't influence it. | Indirectly — decides which tier your branch resolves to (§8.3). |
| `CICD_AGE_ENC` | `$CICD_BASE/etc/age-key.gpg` | Optional gpg-at-rest key blob `unlock-ci` decrypts when no key is piped. Leave unset to only load keys via the pipe form. | No (operator wiring). |

**Concurrency:**

| Key | Default | Controls | Affects authors? |
|---|---|---|---|
| `MAX_JOBS` | `4` | Global cap on simultaneous jobs. | Yes — your job may queue behind others. |
| `SLOT_WAIT_SECS` | `2` | Poll interval while waiting for a free slot. | Marginally (queue latency). |

**Per-job defaults (overridable in the manifest — §2):**

| Key | Default | Controls | Affects authors? |
|---|---|---|---|
| `DEFAULT_IMAGE` | `node:20-alpine` | Image when `image` is unset. | Yes. |
| `DEFAULT_TIMEOUT` | `900` | Wall-clock kill (s) when `timeout` unset; also the max age before runaway containers are killed. | Yes. |
| `DEFAULT_MEMORY` | `2g` | `--memory` default (applied only when `RESOURCE_LIMITS` enforces cgroup limits). | Yes (when enforced). |
| `DEFAULT_PIDS` | `512` | `--pids-limit` default (applied only when `RESOURCE_LIMITS` enforces cgroup limits). | Yes (when enforced). |
| `DEFAULT_NETWORK` | `bridge` | `--network` default. | Yes. |
| `TIMEOUT_MAX` | `86400` | Hard ceiling (s) a per-job `timeout` is clamped to; `0`/garbage falls back to `DEFAULT_TIMEOUT`. | Yes — caps very long `timeout` values. |
| `RESOURCE_LIMITS` | `auto` | `auto` ⇒ detect cgroup-v2/systemd support → apply `--memory`/`--pids-limit`, else fall back to POSIX ulimits (`ULIMIT_NPROC`/`ULIMIT_FSIZE`); `1` ⇒ force cgroup limits; `0` ⇒ no cgroup attempt (ulimits only). | **Yes** — governs whether `memory`/`pids` are enforced (§9). |
| `ULIMIT_NPROC` / `ULIMIT_FSIZE` | `1024` / `2147483648` | POSIX ulimit fallbacks (process cap; single-file byte cap = 2 GiB) applied when no cgroup pids/memory limit is available. | Marginally. |

**Dependency cache reaper:**

| Key | Default | Controls | Affects authors? |
|---|---|---|---|
| `CACHE_MAX_AGE_DAYS` | `30` | Delete `/cache` entries untouched this long. | Yes — old caches expire (cold rebuild). |
| `CACHE_MAX_GB` | `20` | Then size-cap the whole cache (LRU eviction). | Yes — caches may be evicted under pressure. |
| `CACHE_ISOLATION` | `shared` | `shared` = one global cache; `per-repo` gives each repo its own cache subtree (closes cross-repo exec via shared tool config, at the cost of dedup). | Marginally. |
| `LOG_RETENTION_DAYS` | `30` | Delete run logs/metadata older than this. | Yes — old run logs disappear from `ci-job log`/`status`. |
| `LOG_MAX_BYTES` | `52428800` | Cap per-run `output.log` bytes (50 MiB); output past the cap is dropped (the append runs host-side, so the container fsize ulimit doesn't bound it). | Yes — a log-flooding job is truncated. |
| `MASK_MAX_RULES` | `500` | Cap on secret-redaction rules per job (bounds a pathological secrets file from forking the mask builder thousands of times). | No. |

**Behavior:**

| Key | Default | Controls | Affects authors? |
|---|---|---|---|
| `CANCEL_IN_PROGRESS` | `0` | **Declared but has no effect today** — runs always coalesce. Don't rely on it. | No (no-op). |
| `DELETE_SUPERSEDES` | `1` | `1` = a branch-delete cancels a pending build for that branch. | Yes — a delete can pre-empt your queued build. |
| `NOTIFY_BACKSTOP` | `1` | `1` = email on a job failure that emitted no `notify_*` (catches OOM/SIGKILL). | Indirectly (you still get failure alerts). |
| `NOTIFY_CMD` | *(unset — must be set)* | Path to the delivery handler run per notification (§13). **Must be set explicitly** — if empty, ALL delivery (every `notify_*`/`die` and the failure backstop) is silently dropped. The shipped handler you point it at is `notify-email` (SMTP); `notify-wall` also ships. | Yes — determines whether/how your `notify_*` reach a human. |
| `CICD_NOTIFY_HOST_ENV` | `/etc/cicd-runner/notify.env` | Path to the **optional** operator-global SMTP fallback file (§13.2). Read only for keys a repo's tier secrets leave unset. Discouraged for multi-repo. | No. |

**Ephemeral-env reaper:**

| Key | Default | Controls | Affects authors? |
|---|---|---|---|
| `REPORT_STALE_DAYS` | `30` | Log preview envs idle this long for operator attention. | Marginally. |
| `AUTO_REAP_STALE_DAYS` | `0` | `0` = report only; `>0` = auto-teardown after N idle days. | Yes if `>0` — abandoned preview envs get torn down. |

**Audit log (append-only, hash-chained):**

| Key | Default | Controls | Affects authors? |
|---|---|---|---|
| `AUDIT_ENABLED` | `1` | `1` = record security events (ingest/job-start/job-end/key-unlock); `0` = off. | No. |
| `AUDIT_LOG` | `$RUNNER_BASE/audit.log` | Path of the tamper-evident audit log (`ci-audit verify`/`tail`). | No. |
| `AUDIT_LOCK_MAX_SPINS` / `AUDIT_LOCK_STALE_SECS` | `300` / `30` | Lock-contention tuning where `flock` is absent (spin cap; stale-mutex reclaim seconds). | No. |

**Docker context:**

| Key | Default | Controls | Affects authors? |
|---|---|---|---|
| `DOCKER_HOST` | rootless docker socket | Targets the rootless docker daemon. | No. |

**Trusted branches:**

| Key | Default | Status |
|---|---|---|
| `TRUSTED_BRANCHES` | *(unset)* | **Declared but has no effect today.** Don't rely on it. |

**Optional operator-global SMTP fallback file** — `/etc/cicd-runner/notify.env`: holds the same keys
as §13.3/§13.4 as a last-resort default for repos that don't ship their own SMTP creds. No longer
recommended for multi-repo (each repo should put its own creds in its tier secrets). Operator-only;
per-tier `ci/secrets.<env>.enc.yaml` overrides it key-by-key.

### (e) Bootstrap / wrapper env vars (rarely relevant to authors)

Read by host scripts at install/invoke time, not by jobs. The two an author might actually use:

| Var | Default | Meaning |
|---|---|---|
| `CIJOB_POLL` / `CIJOB_POLL_MAX` | `2` / `300` | `--watch` poll interval (s) and max polls before it stops watching. Handy if you script around `ci-job run --watch`. |
| `CI_STATUS_RECENT` | `12` | Number of recent runs shown by `ci-job status`. |
| `NO_COLOR` / `CLICOLOR_FORCE` | *(unset)* | Standard color-off / force-color toggles for `ci-job status` output. |

---

## 15. Complete file templates (copy-paste whole)

Whole files you can save as-is, then trim. No assembly from snippets.

### 15.1 `.gitolite/ci.yml` — a full multi-job workflow

Save at your repo root. Delete the jobs you don't need; the scripts under `run:` are ones you
commit in your repo (see §4 for their bodies).

```yaml
# .gitolite/ci.yml — drop at your repo root. Presence of this file = CI opt-in.
jobs:

  # Run your test script on every push to main.
  test:
    on: { push: { branches: [main] } }
    image: node:lts-bookworm-slim       # ships bash (run: still starts as sh)
    network: bridge                      # needed to install deps
    run: bash ci/test.sh

  # Build + deploy, only when files under site/ change on main. Uses secrets (§15.3).
  deploy-site:
    on:
      push:
        branches: [main]
        paths: ["site/**"]
    image: node:20-alpine
    timeout: 900
    network: bridge
    run: sh ci/deploy-site.sh

  # Preview env for every feat/* branch: create on first push, update on later pushes.
  preview:
    on:
      create: { branches: ["feat/*"] }
      push:   { branches: ["feat/*"], paths: ["site/**"] }
    image: node:20-alpine
    network: bridge
    run: sh ci/preview-deploy.sh         # names resources off preview-$CI_BRANCH_SLUG

  # Tear the preview env down when the feat/* branch is deleted.
  preview-teardown:
    on:
      delete: { branches: ["feat/*"] }
    image: node:20-alpine
    network: bridge
    run: sh ci/preview-teardown.sh
```

### 15.2 `.sops.yaml` — full file (per-tier recipients)

Save at your repo root. Each tier file is encrypted to **its own** runner age key (there is **no
shared master key**) plus your GPG key for editing; human read/edit access narrows as you climb
tiers (higher tiers = superset of humans). Replace the placeholders with each tier's runner age
public key (from your operator) and your GPG fingerprint(s). Add a recipient →
`sops updatekeys ci/secrets.<env>.enc.yaml`.

```yaml
# Per-tier recipients. Runner: one age key PER TIER (dev/qa/prod) — NO shared master key.
# Humans: GPG, tiered (prod ⊇ qa ⊇ dev). Either an age or a PGP recipient can decrypt a file.
creation_rules:
  - path_regex: (^|/)secrets\.prod\.enc\.ya?ml$
    key_groups: [{ age: ["age1PROD_RUNNER"], pgp: ["PROD_FPR"] }]
  - path_regex: (^|/)secrets\.qa\.enc\.ya?ml$
    key_groups: [{ age: ["age1QA_RUNNER"],   pgp: ["QA_FPR","PROD_FPR"] }]
  - path_regex: (^|/)secrets\.dev\.enc\.ya?ml$
    key_groups: [{ age: ["age1DEV_RUNNER"],  pgp: ["DEV_FPR","QA_FPR","PROD_FPR"] }]
```

### 15.3 `ci/secrets.<env>.enc.yaml` — full template (documents every key)

The comprehensive **per-env** secrets template — one file per tier (`ci/secrets.dev.enc.yaml`,
`ci/secrets.qa.enc.yaml`, `ci/secrets.prod.enc.yaml`); the runner decrypts only the resolved tier's
file (§8.3). Save it under the tier name, keep only the sections you need, fill real values, then
encrypt it in place (`sops ci/secrets.<env>.enc.yaml`). Only the deploy creds are required;
everything else is optional. Every top-level key becomes an env var inside the job container, and the
same decrypted set is what supplies that tier's email/SMTP config (§13).

```yaml
# ci/secrets.<env>.enc.yaml — PER-TIER TEMPLATE (documents every key the CI may use).
# ─────────────────────────────────────────────────────────────────────────────
# Do NOT put real values in a template. Create the real ENCRYPTED file per tier with
# sops (it routes secrets.<env>.enc.yaml to THAT tier's own age key via .sops.yaml
# automatically — §15.2). Repeat per tier you deploy (dev/qa/prod):
#
#     sops ci/secrets.dev.enc.yaml    # opens $EDITOR; on save writes ENCRYPTED
#     grep -q ENC ci/secrets.dev.enc.yaml && echo "encrypted ✓"   # before committing
#
# HOW IT REACHES THE JOB: at run time the runner resolves the ENV from the (trusted)
# branch and decrypts ONLY that tier's file host-side into a tmpfs file, with ONLY
# that tier's key, then injects it as `--env-file` into the build container. So EVERY
# key below becomes an ENV VAR inside the container — and the same decrypted set is what
# the email handler reads for SMTP. Keep it FLAT (key: value); only scalars.
#
# Only include the sections you need. All keys are optional except the deploy creds.
# REMEMBER: whoever can push this tier's branch can read this file's secrets.

# ── (A) REQUIRED — Cloudflare Pages deploy (ci/deploy-site.sh) ────────────────
CLOUDFLARE_API_TOKEN: cf-token-with-Account.Cloudflare-Pages.Edit-permission
CLOUDFLARE_ACCOUNT_ID: your-cloudflare-account-id

# ── (B) EMAIL NOTIFICATIONS (SMTP) ───────────────────────────────────────────
# CREDENTIAL SCOPE (read before pasting a login here): whoever can push THIS tier's
# branch can read this file. A personal-identity login (the Gmail App Password below,
# a personal API key) is safe ONLY in a tier restricted to one person — e.g. prod,
# where gitolite @prod = you. In any SHARED tier (dev/qa others can push), do NOT use
# a personal login: use a SEND-ONLY provider key (SES ses:SendEmail, a Postmark send
# token, Resend) whose leak = "send as the CI bot", not "impersonate you" — or omit
# email for that tier entirely.
# Two accepted naming styles per field (first found wins): the Plausible-CE style
# (SMTP_*_ADDR / _PORT / _NAME / _PWD, MAILER_EMAIL) OR the generic aliases. Pick one.
#   host:    SMTP_HOST_ADDR   | SMTP_HOST          (default smtp.gmail.com)
#   port:    SMTP_HOST_PORT   | SMTP_PORT          (587 STARTTLS, or 465 implicit TLS)
#   user:    SMTP_USER_NAME   | SMTP_USER          (your full Gmail address)
#   pass:    SMTP_USER_PWD    | SMTP_PASS          (Gmail *App Password*, 16 chars, 2FA on)
#   to:      NOTIFY_TO        | MAILER_EMAIL       (comma-separated recipients)
#   from:    MAILER_EMAIL     | NOTIFY_FROM        (envelope From; default = user)
SMTP_HOST: smtp.gmail.com
SMTP_PORT: "587"
SMTP_USER: you@gmail.com
SMTP_PASS: your-16-char-app-password
NOTIFY_TO: you@gmail.com, ops@example.com
#
# Optional presentation / behavior:
SMTP_FROM_NAME: PipelineForge CI          # From display name (default "cicd-runner")
NOTIFY_INFO: "0"                           # 1 = also email non-terminal info() notices
NOTIFY_LOGLINES: "30"                      # log-tail lines included in the body
#
# Custom subject/body with {{VAR}} interpolation (omit for sensible defaults).
# Tokens: STATUS TAG REPO BRANCH JOB EVENT SHA SHORT_SHA PUSHER MESSAGE LABEL HOST NOW LOGTAIL
NOTIFY_SUBJECT: "{{TAG}} {{REPO}}/{{BRANCH}} — {{JOB}} {{STATUS}} ({{SHORT_SHA}})"
NOTIFY_BODY: |
  {{STATUS}} — {{JOB}} on {{REPO}}/{{BRANCH}}

  commit:  {{SHORT_SHA}}  by {{PUSHER}}
  event:   {{EVENT}}
  when:    {{NOW}}  on {{HOST}}
  detail:  {{MESSAGE}}

  --- log tail ---
  {{LOGTAIL}}

# ── (C) ANY OTHER BUILD-TIME SECRETS your ci/*.sh needs ───────────────────────
# Whatever you add here is available as an env var in the container. Examples:
# RESEND_API_KEY: re_xxx
# GOOGLE_SA_EMAIL: svc@project.iam.gserviceaccount.com
# GOOGLE_SA_KEY: "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n"
#
# NOTE: these become visible INSIDE the build container. If SMTP creds (section B)
# should NOT be exposed to the build, you may instead put them ONLY in the optional
# operator-global /etc/cicd-runner/notify.env (§15.4) — the email handler falls back
# to that file and it is never mounted into a container. (Host file is discouraged for
# multi-repo; it's the one case where it earns its keep.)
```

### 15.4 `/etc/cicd-runner/notify.env` — OPTIONAL operator-global email fallback (operator-only)

You normally don't touch this, and it's **discouraged for multi-repo** — prefer per-tier creds in
each repo's `ci/secrets.<env>.enc.yaml` (§15.3 B). It's an optional host-wide last-resort SMTP
default the operator may install for repos that ship no email block. Per-tier secrets override it
key-by-key. Included so you know what the fallback looks like.

```sh
# OPTIONAL operator-global email fallback for CI failure alerts.
# Discouraged for multi-repo — prefer per-tier creds in each repo's secrets.
# Install as /etc/cicd-runner/notify.env  (chmod 640, root:cicd-runner).
# Simple KEY=VAL only (no shell features). Per-tier secrets (repo's sops
# ci/secrets.<env>.enc.yaml) OVERRIDE these key-by-key, so this is just a last-resort
# default for projects that don't bring their own.
SMTP_HOST_ADDR=smtp.gmail.com
SMTP_HOST_PORT=587
SMTP_USER_NAME=you@gmail.com
SMTP_USER_PWD="your-16-char-app-password"
MAILER_EMAIL=you@gmail.com         # from + default recipient
# NOTIFY_TO=alerts@example.com      # optional: separate recipient (comma-separated OK)

# --- presentation / behavior (optional) ---
# SMTP_FROM_NAME=cicd-runner        # From display name
# NOTIFY_INFO=0                     # 1 = also email non-terminal info() notices
# NOTIFY_LOGLINES=30                # log-tail lines in the body
# Custom templates with {{VAR}} tokens. Single-line only in this file (\n not
#   expanded) — for a multi-line body prefer the per-project YAML block form.
# NOTIFY_SUBJECT={{TAG}} {{REPO}}/{{BRANCH}} {{JOB}} — {{STATUS}}
# NOTIFY_BODY={{STATUS}} {{JOB}} @ {{SHORT_SHA}} by {{PUSHER}} — {{MESSAGE}}
```
