# Authoring CI jobs for the `cicd-runner`

This is a self-contained guide for authoring a CI job that runs on this repo's hand-rolled
CI/CD runner (`cicd-runner`). It is written for an autonomous agent working in a **different**
repo that is served by the **same** runner. Everything here was verified against the runner
source; field names and paths are quoted exactly as the code reads them.

---

## 1. Mental model (read this first)

- **Archive-push, zero repo access.** The runner never clones or fetches. On every push,
  gitolite's `post-receive` hook runs `git archive` and pipes the tarball (plus the list of
  changed files) through a `sudo` bridge to `cicd-ingest`, which drops it in `incoming/`.
  The runner (`run-group.sh`) extracts that tar and works only from it.
- **One hardened, throwaway container per job.** Each matched job runs in its own
  `docker run --rm --init` container, rootless, with `--cap-drop ALL` and
  `--security-opt no-new-privileges`. The container is destroyed when the job exits.
- **Your `run:` script runs INSIDE that container**, as a shell command:
  `<image> sh -c "<your run: string>"`. The extracted repo tree is mounted at `/work`, which
  is also the working directory (`-w /work`).
- **Opt-in.** A repo participates only if it contains `.gitolite/ci.yml` at its root. No file
  → the hook skips the repo entirely.
- **Jobs are self-contained.** The image is a stock base image (e.g. `alpine`, `node:...`).
  Nothing repo-specific is pre-installed. If your job needs a tool, install it inside the
  `run:` script (apt / apk / npm / pip / ...). See §7.

---

## 2. The manifest: `.gitolite/ci.yml`

**Exact path:** `.gitolite/ci.yml` at the **root of your repo**. The runner reads it from the
archived tree as `<extracted>/.gitolite/ci.yml` (`run-group.sh`:
`manifest="$work/.gitolite/ci.yml"`). Any other path/name is invisible to the runner.

It is YAML, parsed with `yq` (mikefarah v4). Top level is a `jobs:` map; each key under it is
a job name.

### 2.1 Field reference

Only the fields below are actually read by the runner (`run-group.sh` via `yq_str` / `yq_keys`
/ `yq_list`). Anything else in the file is **ignored** (see §9 for two fields that appear in
examples but are NOT read).

Per-job fields under `jobs.<name>`:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `run` | string | *(none — required)* | Shell command run as `sh -c "<run>"` inside the container, cwd `/work`. If empty/missing, the job is skipped with a log line. **This is the only required field.** |
| `image` | string | `DEFAULT_IMAGE` (configured as `node:20-alpine`) | Docker image to run the job in. |
| `timeout` | int (seconds) | `DEFAULT_TIMEOUT` (configured `900`) | Wall-clock kill. Exceeding it = status `timeout` (exit 124). |
| `memory` | docker mem string (e.g. `2g`) | `DEFAULT_MEMORY` (`2g`) | `--memory` limit. **Only applied when the runner has `RESOURCE_LIMITS=1`** (cgroup v2 + systemd). This repo's runner runs OpenRC rootless with `RESOURCE_LIMITS=0`, so memory/pids limits are silently omitted. |
| `pids` | int | `DEFAULT_PIDS` (`512`) | `--pids-limit`. Same `RESOURCE_LIMITS` caveat as `memory`. |
| `network` | `bridge` \| `none` | `DEFAULT_NETWORK` (`bridge`) | Container network mode. `bridge` = outbound network; `none` = no network. |
| `env` | map of `KEY: value` | *(none)* | Plaintext env vars injected as `-e KEY=value`. Injected **after** the `CI_*`/cache vars (so it can override them) but **before** decrypted secrets (so a secret still wins). |
| `on.<event>` | map | *(none)* | Trigger config — see below. Presence of the matching event key is required for the job to fire on that event. |

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
- `create` — a branch first appears (its first push). Note: a brand-new branch fires the
  `create` event, **not** `push`. If you want CI on a new branch, give the job an
  `on.create` trigger too (or use the manual `ci-job run`).
- `delete` — a branch is deleted → runs as a *teardown* job. A job is a teardown job iff it
  has an `on.delete` key.

**Glob semantics** (`lib.sh` `glob_to_regex`, GitHub-Actions-ish): `*` matches within one path
segment (not `/`), `**` matches across `/`, `?` matches one non-`/` char. Lists may be
YAML arrays or comma/space separated.

### 2.2 Branch-filter truth table (verified in code)

`branch_matches(branch, include, ignore)` in `lib.sh`:
- If `ignore` is set and matches the branch → **no run**.
- Else if `include` is empty/omitted → **run** (match-all).
- Else → run only if the branch matches `include`.

**Important nuance:** the job only even *reaches* the branch filter if the
`on.<event>` key exists. The runner does
`[ -n "$(yq_str ... .jobs.<name>.on.<event>)" ] || continue`. So:
- `on: { push: { branches: [main] } }` → runs on push to `main` only.
- `on: { push: {} }` → `push` key present, `branches` empty → runs on **every** push to any
  branch.
- A job with no `on.push` at all → never runs on a push (regardless of branch).

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

Commit this as `.gitolite/ci.yml` at your repo root, then push to your default branch
(`main`). It uses the stock `alpine` image, no secrets, no deps, no network.

```yaml
jobs:
  hello:
    on: { push: { branches: [main] } }
    image: alpine
    run: echo hello world
```

Why this is guaranteed to fire and pass:
- The `on.push` key is present and `branches: [main]` matches a push to `main`.
- `image: alpine` is a stock image; `echo` is a busybin builtin — no installs, no network.
- `run` exits 0 → run status `exit:0`.
- If your default branch is not `main`, change `[main]` to your branch name, or use
  `on: { push: {} }` to run on every branch.

If the branch is brand new (its very first push), `push` won't fire — the event is `create`.
For a first-push-on-a-new-branch case use `on: { push: { branches: [main] }, create: { branches: [main] } }`,
or just trigger manually with `ci-job run` (§8).

---

## 4. Helper library: `/cicd/lib.sh`

The runner mounts `cicd-runner/lib/cicd.sh` read-only at **`/cicd/lib.sh`** in every container.
It is POSIX sh (works in busybox `ash`). Source it at the top of your `run:` script:

```sh
. /cicd/lib.sh
```

Functions a job author will use (signatures verified in `lib/cicd.sh`):

| Function | Signature | Use |
|---|---|---|
| `step` | `step <name...>` | Print a `=== name ===` stage marker into the run's `output.log`. |
| `retry` | `retry [-n tries] [-d delay] -- <cmd...>` | Retry one command (default 3 tries, 10 s apart). Retries the single command, not the whole job. e.g. `retry -n 3 -d 5 -- apt-get update`. |
| `wait_all` | `wait_all <pid>...` | Fan-in: wait on background pids; returns 1 if any failed. |
| `die` | `die <message...>` | `notify_error` + print `FATAL:` + `exit 1`. |
| `notify` | `notify <message...>` | Informational notification (appended to the run's outbox; delivered host-side). |
| `notify_success` | `notify_success <message...>` | Terminal success notification (`[CI OK]`). |
| `notify_error` | `notify_error <message...>` | Terminal failure notification (`[CI FAIL]`). |

Notes on notifications: `notify*` do **not** send mail from inside the container. They append
to a mounted outbox file; the runner delivers them host-side after the container exits (so it
works in any image, needs no curl/creds in the container, and still fires even if the job is
OOM/timeout-killed). There is also a backstop: a job that exits non-zero **without** emitting a
terminal notification still triggers a failure alert.

`retry`, `notify`, etc. are the home for retry/notify logic — they are **not** manifest fields.

> **Want emails (e.g. SMTP)?** That is the *delivery* half of notifications and it is configured
> by the OPERATOR, not in the manifest — but a repo **can** ship its own SMTP credentials in its
> encrypted secrets so failure alerts go to *your* mailbox. See **§12** for the full author-vs-
> operator boundary and the exact secret keys (e.g. `SMTP_HOST_ADDR`, `SMTP_USER_PWD`, `NOTIFY_TO`).

---

## 5. Environment available inside the job

Injected env vars (set on the `docker run`):

| Var | Meaning |
|---|---|
| `CI_EVENT` | `push`, `create`, or `delete` (a manual `ci-job run` reports as `push`). |
| `CI_REPO` | Repo name (gitolite repo path, e.g. `tovasol/agent-forge`). |
| `CI_BRANCH` | The exact branch name. |
| `CI_BRANCH_SLUG` | DNS-safe slug of the branch (lowercased, non-alnum → `-`, + 6-char hash). Use this to name external resources (preview envs, etc.). |
| `CI_SHA` | The commit sha being built. |
| `CI_PUSHER` | The gitolite user who triggered it. |
| `CI_CACHE_DIR` | `=/cache` (the shared cache mount, see below). |
| `CI_ENV_DIR` | `=/envstate` — a per-(repo,branch) persistent state dir mounted at `/envstate`, for ephemeral-env bookkeeping/teardown. |
| `CI_OUTBOX` | `=/cicd/out/notify` — the notify outbox (used by `/cicd/lib.sh`; you don't write it directly). |
| Cache vars | Many package-manager cache vars are pre-pointed into `/cache` (see §6). |
| Secret vars | If you ship `ci/secrets.enc.yaml`, each decrypted key appears as an env var (§7.3). |
| `env:` vars | Any `jobs.<name>.env` map entries. |

Filesystem:
- **`/work`** — the extracted repo tree, and the working directory (cwd) of your `run:` command.
  So `sh ci/test.sh` resolves to `/work/ci/test.sh`, and relative paths work.
- **`/cache`** — a single global cache volume shared across all repos and runs. Writable.
  Persisted between runs; age- and size-capped by a reaper.
- **`/envstate`** (`CI_ENV_DIR`) — small persistent per-branch state dir.
- **`/cicd/lib.sh`** — the helper library (read-only).
- **`/cicd/out`** — the notify outbox dir (read-write; written via the lib).

---

## 6. The dependency cache (`/cache`)

The runner injects a static block of cache env vars pointing every common package manager at
`/cache`, so dependency installs are cached across runs automatically — no per-repo wiring.
Examples (full list in `run-group.sh` `CACHE_ENV`):

```
CI_CACHE_DIR=/cache  XDG_CACHE_HOME=/cache/xdg
npm_config_cache=/cache/npm  YARN_CACHE_FOLDER=/cache/yarn  pnpm_config_store_dir=/cache/pnpm/store
PIP_CACHE_DIR=/cache/pip  POETRY_CACHE_DIR=/cache/poetry  UV_CACHE_DIR=/cache/uv
GOMODCACHE=/cache/go/mod  GOCACHE=/cache/go/build  CARGO_HOME=/cache/cargo
COMPOSER_CACHE_DIR=/cache/composer  NUGET_PACKAGES=/cache/nuget
GRADLE_USER_HOME=/cache/gradle  MAVEN_ARGS=-Dmaven.repo.local=/cache/maven
BUNDLE_PATH=/cache/bundle  DENO_DIR=/cache/deno  MIX_HOME=/cache/mix  HEX_HOME=/cache/hex
```

If your tool isn't listed, point it at `$XDG_CACHE_HOME` (`/cache/xdg`) or `$CI_CACHE_DIR`
(`/cache`) yourself. `apt` archives are deliberately NOT cached (see §7.1).

---

## 7. Self-contained jobs: installing your own dependencies

Nothing repo-specific is pre-installed. Install what you need inside the `run:` script.

### 7.1 apt (Debian/Ubuntu images) — works out of the box

The runner applies an image-agnostic fix (`APT_HARDEN`) to every container so that
`apt-get install` works under the hardened rootless runner without the job needing any
workaround. (It sets `APT::Sandbox::User "root"` and mounts a fresh tmpfs at apt's
cache/lists dirs.) So you can just:

```sh
. /cicd/lib.sh
retry -n 3 -d 5 -- apt-get update -qq
apt-get install -y -qq --no-install-recommends curl unzip ca-certificates
```

(apt archives are not cached across runs by design; the expensive caches — npm/pip/cargo/go/
maven/... — already persist on `/cache`.)

### 7.2 Other package managers

apk (alpine), npm/pnpm/yarn, pip/poetry/uv, cargo, go, etc. all work and are cached via
`/cache` automatically. Example (alpine):

```sh
apk add --no-cache curl jq
```

For pinned, sha256-verified **stack** tools (yq, duckdb, ...), the runner ships
`cicd-runner/bin/fetch-tools.sh` — but that is for the CI/CD stack's own tools, cached under
`/cache/tools`. **Per-repo build deps belong in your job container** via apt/apk/npm/etc., not
fetch-tools.

### 7.3 Secrets (sops + age)

Secrets are sops-encrypted files committed **in your repo** (ciphertext only — never plaintext).
The runner decrypts them host-side and injects each key as an env var into your job container.
There is **no `secrets:` manifest field**; the runner keys entirely off the *presence* of the
encrypted file (see §9).

#### Where the files go (exact paths)

```
<repo root>/
├── .sops.yaml                 # sops recipients (who can decrypt). Repo root. REQUIRED to encrypt.
└── ci/
    ├── secrets.enc.yaml       # the ENCRYPTED secrets (committed). Runner reads THIS path exactly.
    └── secrets.example.yaml   # optional plaintext TEMPLATE for humans (never the real secret)
```

The runner only ever reads **`ci/secrets.enc.yaml`** (hard-coded path in `run-group.sh`). The
`.sops.yaml` and the example template are author/operator conveniences.

#### Step 1 — `.sops.yaml` at the repo root (declares who may decrypt)

This tells `sops` which recipients to encrypt to. Two kinds: a human GPG key (you, for editing)
and the **CI runner's age public key** (passphraseless, so the runner decrypts unattended).
Either recipient can decrypt. Get the runner's age public key (an `age1…` string) and confirm
your own GPG fingerprint from your operator. Copy this file verbatim and replace the two
placeholders:

```yaml
# sops recipients for this repo. Humans decrypt via GPG (pass/YubiKey); the CI
# runner decrypts via its passphraseless age key (unattended). Either decrypts.
# Replace the placeholders. Add a recipient -> `sops updatekeys ci/secrets.enc.yaml`.
creation_rules:
  - path_regex: \.enc\.(ya?ml|json|env)$
    pgp: "REPLACE_WITH_YOUR_GPG_FINGERPRINT"
    age: "age1replace_with_cicd_runner_public_key"
```

#### Step 2 — write, encrypt, commit `ci/secrets.enc.yaml`

Each top-level key becomes an **env var** inside your job (via `sops -d --output-type dotenv`).
This is the canonical template — copy it to `ci/secrets.example.yaml`, then follow its own header
to produce the encrypted file. It also shows the **opt-in per-repo email/SMTP keys** (see §12):

```yaml
# TEMPLATE ONLY — do NOT commit this plaintext. Create the real encrypted file:
#
#   cp ci/secrets.example.yaml /tmp/s.yaml      # fill in real values in /tmp
#   sops --encrypt /tmp/s.yaml > ci/secrets.enc.yaml   # encrypts to .sops.yaml recipients
#   git add ci/secrets.enc.yaml && git commit && git push     # ciphertext only
#   shred -u /tmp/s.yaml
#
# Keys here become ENV VARS inside the job container (via sops -> dotenv).
cloudflare_api_token: cf_xxxxxxxxxxxxxxxxxxxxxxxx   # Pages:Edit, scoped to this project
cloudflare_account_id: 0123456789abcdef0123456789abcdef
# npm_token: npm_xxxxxxxxxxxxxxxxxxxx              # if using a private registry (.npmrc ${NPM_TOKEN})

# --- OPTIONAL: per-project email notifications (opt-in) ---
# Include these to have THIS repo's failures emailed using its own SMTP creds.
# Omit them to fall back to the operator-global /etc/cicd-runner/notify.env (or no
# email if that's absent). The job must also have notify: on-failure (the default).
# SMTP_HOST_ADDR: smtp.gmail.com
# SMTP_HOST_PORT: "587"
# SMTP_USER_NAME: you@gmail.com
# SMTP_USER_PWD: your-app-password
# MAILER_EMAIL: you@gmail.com        # from + recipient
# NOTIFY_TO: alerts@example.com      # optional separate recipient
```

> Note on that template's wording: `notify: on-failure (the default)` is **not** a real manifest
> field — there is no `notify:` key. Job *failures* are emailed automatically by the runner's
> backstop, and you emit explicit notifications from your script via the `/cicd/lib.sh` helpers.
> The SMTP keys above only configure *delivery* for this repo. Full picture in §12.

#### Behavior contract

- **Trigger = file presence.** `ci/secrets.enc.yaml` exists → the runner decrypts + injects. No
  manifest field opts in.
- **Each key → one env var** in the `run:` script's environment (`cloudflare_api_token`, etc.).
- **Key not loaded → deferred, not failed.** If the file is present but the runner's age key
  isn't unlocked on the host, the run is held pending and auto-runs once the operator unlocks it.
- **Decrypt failure → status `secrets-decrypt-failed`** (e.g. you encrypted to the wrong
  recipient — re-run `sops updatekeys ci/secrets.enc.yaml`).
- The decrypted values live only in a tmpfs env-file for the container's lifetime; the age key
  never enters the job container.

---

## 8. Constraints the author MUST respect

- **Hardened rootless container.** `--cap-drop ALL` and `--security-opt no-new-privileges`.
  This forbids anything needing Linux capabilities or privilege escalation: no mounting, no
  raw sockets, no setuid/`sudo`-up, no `setcap`, no changing kernel params, no privileged
  ports below 1024 binding tricks that need caps.
- **No Docker-in-Docker / no docker access.** Jobs cannot run `docker`, build images, or reach
  the host docker socket. There is no docker binary or socket in the container.
- **Jobs must be self-contained.** Assume only what the base image ships. Install your own deps
  (§7). apt works thanks to the runner's apt fix.
- **Resource limits** (`memory`, `pids`) are only enforced when the runner has
  `RESOURCE_LIMITS=1`. This repo's runner is OpenRC rootless (`RESOURCE_LIMITS=0`), so those
  two are no-ops here. `timeout`, `network`, and the cap/no-new-priv hardening always apply.
- **Network modes:** `bridge` (outbound) or `none`. Default `bridge`. Use `none` for offline
  jobs.
- **Path filters** apply to real pushes only. A manual `ci-job run` skips path filters (and
  `ci-job run --job <name>` skips branch *and* path filters too).
- **Secrets need sops/age** and an operator-loaded key (§7.3).
- **`run:` is `sh -c`.** It runs in `sh`, not bash. If you need bash, either set
  `image:` to one that has bash and invoke `bash yourscript.sh`, or keep the `run:` string
  POSIX. The example test job uses `node:lts-bookworm-slim` precisely because it ships bash.

---

## 9. Two fields that look real but are IGNORED

Some example manifests in this repo show fields the runner does **not** read. Do not rely on
them:
- **`version:`** — appears at the top of examples; `run-group.sh` never reads it. Harmless, but
  it does nothing.
- **`secrets: [ ... ]`** — appears under jobs in `examples/.gitolite/ci.yml`; the runner does
  **not** read it. Secrets are driven entirely by the presence of `ci/secrets.enc.yaml`
  (§7.3). Listing `secrets:` has no effect.

(These are flagged so you don't copy a non-functional field expecting behavior.)

---

## 10. Trigger and observe a run (self-verify your hello-world)

Normal flow: just `git push` to the repo; the hook triggers CI automatically if
`.gitolite/ci.yml` is present. To trigger manually or to watch/inspect, use the `ci-job`
gitolite command over ssh (scoped to repos your ssh key may access):

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

What you'll see and what "green" means:
- `ci-job run ... --watch` polls and prints status transitions, e.g.
  `queued → running → exit:0`. **`exit:0` (or `success`) = green.** `exit:N` (N≠0),
  `timeout`, or `secrets-decrypt-failed` = red.
- If `--watch` shows nothing for a while and prints
  `(not started yet - queued; ... docker/key may not be ready)`, the run was *deferred* —
  docker is down or a needed age key isn't loaded. Run `ci-job status` to check; it is not a
  failure of your job.
- `--watch` follows *status*; to read the actual output use `ci-job log ... -f`.

(`run` requires WRITE access to the repo; `status`/`log` require READ. Access is enforced by
gitolite against your ssh key.)

---

## 11. Common mistakes checklist

- [ ] **Wrong manifest path.** It must be exactly `.gitolite/ci.yml` at the repo root, and
      committed. No file → nothing happens (silent).
- [ ] **Assuming tools are pre-installed.** They are not. Install deps in `run:` (§7).
- [ ] **Expecting docker.** No DinD, no docker socket — jobs cannot build/run containers.
- [ ] **Wrong branch filter.** Omitting `on.<event>` entirely means the job never fires on
      that event; an empty `branches:` means *all* branches (not none). See §2.2.
- [ ] **First push to a new branch.** That's a `create` event, not `push`. Add `on.create` or
      use `ci-job run`.
- [ ] **`run:` is `sh`, not bash.** Use a bash image + `bash script.sh` if you need bash.
- [ ] **Counting on `memory`/`pids` limits.** No-op on this OpenRC rootless runner
      (`RESOURCE_LIMITS=0`).
- [ ] **Using a `secrets:` or `version:` field.** Ignored. Secrets = presence of
      `ci/secrets.enc.yaml`.
- [ ] **Privileged operations.** `cap-drop ALL` + `no-new-privileges` forbid mounting, setcap,
      sudo-up, raw sockets, etc.
- [ ] **Relying on path filters via manual run.** `ci-job run` skips path filters by design.

---

## 12. Notifications & email (SMTP): author vs operator

Notifications have **two halves**, and they are owned by different people. Getting this boundary
right is the whole point of this section.

```
 AUTHOR (in your repo)                         OPERATOR (host config)
 ─────────────────────                         ─────────────────────
 emit notifications from your run: script      configure DELIVERY (how/where they're sent)
   . /cicd/lib.sh                                NOTIFY_CMD   -> a handler script
   notify "deploy starting"                      notify-email -> SMTP via curl   (§12.2)
   notify_success "deployed ok"                  notify-wall  -> wall(1) broadcast
   notify_error  "deploy failed"
   die "fatal"                                  + per-project OR operator-global SMTP creds
                                                  (§12.3 — THIS is where the secrets file
 (you NEVER touch SMTP from inside the job)        comes in)
```

- **As a job author** you only ever call the `/cicd/lib.sh` helpers (`notify`, `notify_success`,
  `notify_error`, `die`) from §4. They append a line to a mounted outbox; **nothing is sent from
  inside your container** (no curl, no creds, no network needed in the job).
- **After the container exits**, the runner (`lib/cicd.sh` → `cicd_flush_outbox` → `cicd_deliver`)
  reads the outbox host-side and runs the operator's `NOTIFY_CMD` once per notification, plus a
  **backstop** alert if the job failed (`rc≠0`) and emitted no terminal `notify_success`/`error`
  (catches OOM/SIGKILL and scripts that forgot to notify). The backstop is on unless the operator
  sets `NOTIFY_BACKSTOP=0`.

### 12.1 What the handler is

`NOTIFY_CMD` (in `runner.conf`) is the host-side program the runner invokes as
`NOTIFY_CMD <group> <level: message> <logpath>`. Two handlers ship with the runner:

| Handler | What it does |
|---|---|
| `bin/notify-email` | Emails the alert over **SMTP using `curl`** (no extra packages). Default `NOTIFY_CMD`. |
| `bin/notify-wall.sample` | Broadcasts to logged-in terminals via `wall(1)` (sample; rename to use). |

`notify-email` only emails **terminal** events by default — `notify_success` (`[CI OK]`) and
`notify_error`/`die` (`[CI FAIL]`) plus the failure backstop. Plain `notify` (info) is **not**
mailed unless `NOTIFY_INFO=1` is set (§12.4).

### 12.2 The literal question: can SMTP creds go in `ci/secrets.enc.yaml`? — **Yes.**

`bin/notify-email` runs **host-side** (not in your job container), but it is explicitly designed to
read **per-project SMTP config from your repo's decrypted secrets first**, then fall back to an
operator-global file. The exact precedence, from the code (`bin/notify-email`, `read_var`):

1. **Your repo's decrypted secrets** — the runner passes the path to your decrypted
   `ci/secrets.enc.yaml` to the handler via the env var `CICD_NOTIFY_ENV` (set in
   `lib/cicd.sh` `cicd_deliver`). `notify-email` reads keys out of that file **first**.
2. **Operator-global fallback** — `/etc/cicd-runner/notify.env` (see `etc/notify.env.sample`),
   used only for keys your secrets don't provide.

So a repo opts into **its own** email destination/credentials simply by putting the keys below into
`ci/secrets.enc.yaml`. No manifest field, no operator change required (as long as the operator left
`NOTIFY_CMD` pointed at `notify-email`, the default). **Each variable is resolved independently** —
you can supply only `NOTIFY_TO` in your secrets and inherit the host's SMTP server, or supply
everything.

> Caveat to state plainly: the mailer is **host-side**, so it can only use secrets the runner could
> decrypt — i.e. the host's age key must be loaded (the same key that gates secret-using jobs, §7.3).
> The credentials are read from your *decrypted* secrets at delivery time; they never run inside the
> container and are never exposed to your job's env unless you also reference them in `run:`.

### 12.3 SMTP / email variable reference (exact names from `bin/notify-email`)

These go in **`ci/secrets.enc.yaml`** (per-repo) and/or **`/etc/cicd-runner/notify.env`**
(operator-global). The primary names match **Plausible CE**'s SMTP config so you can reuse the same
values; a generic alias is accepted for each (the handler tries the primary name, then the alias):

| Primary key | Alias | Default (if unset) | Meaning |
|---|---|---|---|
| `SMTP_HOST_ADDR` | `SMTP_HOST` | `smtp.gmail.com` | SMTP server hostname. |
| `SMTP_HOST_PORT` | `SMTP_PORT` | `587` | SMTP port. **Port `465` ⇒ implicit TLS (`smtps://`); any other port (587/25) ⇒ STARTTLS on `smtp://`** — chosen automatically from the port, there is no separate TLS flag. |
| `SMTP_USER_NAME` | `SMTP_USER` | *(none)* | SMTP/auth username. **Required** — if empty, the mailer silently skips (no email). |
| `SMTP_USER_PWD` | `SMTP_PASS` | *(none)* | SMTP/auth password (for Gmail, a 16-char App Password). **Required.** |
| `MAILER_EMAIL` | *(used as `FROM`/recipient default)* | falls back to `SMTP_USER_NAME` | The `From:` address; also the default recipient if `NOTIFY_TO` is unset. |
| `NOTIFY_TO` | `MAILER_EMAIL` | falls back to `SMTP_USER_NAME` | Recipient(s). Comma-separated is accepted. **Required** (directly or via fallback). |
| `NOTIFY_FROM` | *(read only as fallback for `FROM`)* | falls back to `MAILER_EMAIL`/`SMTP_USER_NAME` | Alternative `From:` source. |
| `SMTP_FROM_NAME` | `NOTIFY_FROM_NAME` | `cicd-runner` | `From:` display name. |

Auth: the handler always authenticates with `curl --user "$USER:$PASS" --ssl-reqd`. There is no
"no-auth" mode — `SMTP_USER_NAME` **and** `SMTP_USER_PWD` **and** a recipient must all resolve or the
mailer exits 0 without sending (never blocks/fails the job). Minimum to get mail to your inbox from a
per-repo secrets file: `SMTP_USER_NAME`, `SMTP_USER_PWD`, and either `NOTIFY_TO` or `MAILER_EMAIL`.

### 12.4 Presentation / behavior knobs (same two locations, optional)

| Key | Default | Meaning |
|---|---|---|
| `NOTIFY_INFO` | `0` | `1` = also email non-terminal `notify` (info) notices, not just success/fail. |
| `NOTIFY_LOGLINES` | `30` | How many trailing lines of the run's `output.log` to include in the body. |
| `NOTIFY_SUBJECT` | `{{TAG}} {{REPO}}/{{BRANCH}} {{JOB}} — {{STATUS}}` | Custom subject template. |
| `NOTIFY_BODY` | *(built-in multi-line block)* | Custom body template. In the **YAML** secrets file you can use a multi-line block scalar; in the flat `notify.env` file it must be single-line (`\n` is not expanded). |

Template tokens (literal `{{...}}` substitution — **no** eval; message/log are treated as untrusted):
`{{STATUS}}` `{{TAG}}` `{{REPO}}` `{{BRANCH}}` `{{JOB}}` `{{EVENT}}` `{{SHA}}` `{{SHORT_SHA}}`
`{{PUSHER}}` `{{MESSAGE}}` `{{LABEL}}` `{{HOST}}` `{{NOW}}` `{{LOGTAIL}}`. The non-secret fields
(`REPO`, `BRANCH`, `SHA`, etc.) are enriched from the run's `meta.json` host-side.

### 12.5 Author checklist for "email me on CI failure"

1. Keep `notify_error`/`die` (or rely on the failure backstop) in your `run:` script — §4.
2. Add SMTP keys to `ci/secrets.enc.yaml`, e.g.:
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
   (sops-encrypt it against the runner's age recipient — §7.3.) Quote numeric values so the
   dotenv export keeps them as strings.
3. That's it — the operator's default `NOTIFY_CMD=notify-email` picks these up. You do **not** edit
   `runner.conf` or `notify.env`; those are operator-only (§13d). If the operator repointed
   `NOTIFY_CMD` at something else, ask them.

---

## 13. Configuration & environment reference (full surface)

Everything the framework reads, grouped by **who sets it** and **where**. Every variable below was
verified against the code; the file/why is given. Vars marked **operator config** are listed so you
know the feature exists, but you **cannot** set them as a job author — they live in host files you
don't control.

### (a) Job author — in the manifest `.gitolite/ci.yml`

Fully covered in **§2**. The complete set of fields the runner actually reads
(`run-group.sh` via `yq_*`): per-job `run`, `image`, `timeout`, `memory`, `pids`, `network`, `env`,
and `on.<push|create|delete>` with `branches`, `branches-ignore`, `paths`, `paths-ignore`.
Anything else in the file is ignored (`version:`, `secrets:` — §9). Nothing is missing from §2.

### (b) Job author / repo — via conventional files in your repo

The runner looks for exactly these repo-relative paths (verified in `run-group.sh` / `post-receive`):

| Path | Read by | Purpose |
|---|---|---|
| `.gitolite/ci.yml` | hook `have_ci`, `run-group.sh` `manifest=` | The manifest. Its presence is the **opt-in gate** (§2). |
| `ci/secrets.enc.yaml` | `run-group.sh` (`sops -d --output-type dotenv`) | Encrypted secrets → injected as `--env-file`; **also the source of per-repo SMTP creds** (§12.3). Presence is the trigger; there is no `secrets:` field. |

There are **no other** magic repo paths. (`ci/*.sh` scripts only exist because *your* `run:` calls
them — the runner doesn't look for them.)

### (c) Inside-container environment your job receives

Injected on the `docker run` (verified in `run-group.sh` `execute_job` / `run_teardown` and the
`CACHE_ENV` block). This is the COMPLETE list.

**CI_* identity/context vars:**

| Var | Value / meaning |
|---|---|
| `CI_EVENT` | `push`, `create`, or `delete` (manual `ci-job run` reports as `push`). |
| `CI_REPO` | Gitolite repo path, e.g. `tovasol/agent-forge`. |
| `CI_BRANCH` | Exact branch name. |
| `CI_BRANCH_SLUG` | DNS-safe slug of the branch (lowercased, non-alnum→`-`, +6-char sha1). |
| `CI_SHA` | Commit sha being built. *(Not set on `delete`/teardown — there is no new tree.)* |
| `CI_PUSHER` | Gitolite user who triggered it. |
| `CI_CACHE_DIR` | `/cache` — the shared cache mount (§6). |
| `CI_ENV_DIR` | `/envstate` — persistent per-(repo,branch) state dir (mounted from `envs/<repo>/<slug>`). |
| `CI_OUTBOX` | `/cicd/out/notify` — the notify outbox path used by `/cicd/lib.sh` (don't write it directly). |

**Cache vars (`CACHE_ENV`, complete — every entry points a package manager at `/cache`):**

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
| `MAVEN_ARGS` | `-Dmaven.repo.local=/cache/maven` | Maven (note: an arg, not a dir var) |
| `DENO_DIR` | `/cache/deno` | Deno |
| `MIX_HOME` | `/cache/mix` | Elixir mix |
| `HEX_HOME` | `/cache/hex` | Elixir hex |

**Then, layered on top (later wins):** your `jobs.<name>.env` map (plaintext `-e KEY=value`),
then decrypted secrets from `ci/secrets.enc.yaml` (`--env-file`, so a secret with the same name
**overrides** an `env:` entry, which in turn overrides the `CI_*`/cache defaults).

> Note: `RESOURCE_LIMITS=0` on this runner means `--memory`/`--pids-limit` are omitted (§8); the
> container still gets `--cap-drop ALL`, `--security-opt no-new-privileges`, `--network`, the
> wall-clock `timeout`, and the `APT_HARDEN` apt fix.

### (d) Operator / host config — `runner.conf` (and friends)

These live in `runner.conf` (`$CICD_BASE/etc/runner.conf` or `/etc/cicd-runner/runner.conf`),
loaded by `cicd_load_config` (`bin/lib.sh`) into every host-side script. **Operator config, not
author-settable** — listed so you know the feature surface and its defaults. "Affects authors?"
flags what changes the behavior or limits of your jobs.

**Identity / paths:**

| Key | Default | Controls | Affects authors? |
|---|---|---|---|
| `RUNNER_USER` | `cicd-runner` | Unix user the runner/containers run as. | Indirectly (rootless uid). |
| `RUNNER_BASE` | `/home/cicd-runner/runner` | Root of `queue/ runs/ cache/ envs/ slots/ incoming/`. | No. |
| `GIT_REPO_BASE` | `/home/git/repositories` | Documented as where gitolite bare repos live. **Declared in the sample but not read by any runner script** (the hook uses gitolite's own `GL_REPO`/cwd; `ci-job` uses `gitolite query-rc GL_REPO_BASE`). Effectively informational. | No. |
| `LOCAL_BIN` | `/home/cicd-runner/.local/bin` | Dir prepended to `PATH` so the runner finds `sops`/`yq`/`age` under `sudo`. | No. |

**Secrets (sops + age):**

| Key | Default | Controls | Affects authors? |
|---|---|---|---|
| `SOPS_AGE_KEY_FILE` | `/run/ci-keys/age-keys.txt` | Path to the decrypted age key (ramfs; populated by `unlock-ci`). Its presence gates secret-using jobs and the host-side mailer. | Yes — if unloaded, secret jobs **defer**, and per-repo SMTP creds can't be read. |
| `SHM_DIR` | `/dev/shm` | tmpfs where decrypted env-files are written transiently. | No. |

**Concurrency:**

| Key | Default | Controls | Affects authors? |
|---|---|---|---|
| `MAX_JOBS` | `4` | Global cap on simultaneous `docker run`s (slot semaphore in `bin/lib.sh` `acquire_slot`; also seeded by `install.sh`, shown by `ci-status`). | Yes — your job may queue behind others. |
| `SLOT_WAIT_SECS` | `2` | Poll interval while waiting for a free slot (`acquire_slot`). | Marginally (queue latency). |

**Per-job defaults (overridable in the manifest — §2):**

| Key | Default | Controls | Affects authors? |
|---|---|---|---|
| `DEFAULT_IMAGE` | `node:20-alpine` | Image when `jobs.<name>.image` is unset. | Yes (default image). |
| `DEFAULT_TIMEOUT` | `900` | Wall-clock kill (s) when `timeout` unset. Also used by `reap-containers` as the max age for killing runaway containers. | Yes. |
| `DEFAULT_MEMORY` | `2g` | `--memory` default (only if `RESOURCE_LIMITS=1`). | Yes (when enforced). |
| `DEFAULT_PIDS` | `512` | `--pids-limit` default (only if `RESOURCE_LIMITS=1`). | Yes (when enforced). |
| `DEFAULT_NETWORK` | `bridge` | `--network` default (`bridge`/`none`). | Yes. |
| `RESOURCE_LIMITS` | `0` | `1` ⇒ apply `--memory`/`--pids-limit`; `0` ⇒ omit them (OpenRC rootless can't enforce). | **Yes** — at `0`, `memory`/`pids` manifest fields are no-ops (§8). |

**Dependency cache reaper (`bin/prune-disk`):**

| Key | Default | Controls | Affects authors? |
|---|---|---|---|
| `CACHE_MAX_AGE_DAYS` | `30` | Delete `/cache` entries untouched this long. | Yes — old caches expire (cold rebuild). |
| `CACHE_MAX_GB` | `20` | Then size-cap the whole cache (LRU eviction). | Yes — caches may be evicted under pressure. |
| `LOG_RETENTION_DAYS` | `30` | Delete run dirs (logs/meta) older than this. | Yes — old run logs disappear from `ci-job log`/`status`. |

**Behavior:**

| Key | Default | Controls | Affects authors? |
|---|---|---|---|
| `CANCEL_IN_PROGRESS` | `0` | *Intended:* `1` = a new push kills the running job; `0` = coalesce. **Declared in the sample but NOT read by any code** — coalescing is always the behavior today. Documented as a known no-op so you don't rely on it. | No (no-op). |
| `DELETE_SUPERSEDES` | `1` | `1` = a branch-delete cancels/overrides a pending build for that group (`run-group.sh` main loop). | Yes — a delete can pre-empt your queued build. |
| `NOTIFY_BACKSTOP` | `1` | `1` = email on a job failure that emitted no script `notify_*` (catches OOM/SIGKILL). Read in `lib/cicd.sh` `cicd_flush_outbox`. | Indirectly (you still get failure alerts). |
| `NOTIFY_CMD` | `…/bin/notify-email` | Host-side notification handler invoked per notification (§12). | Yes — determines whether/how your `notify_*` reach a human. |

**Ephemeral-env reaper (`bin/reap-envs`):**

| Key | Default | Controls | Affects authors? |
|---|---|---|---|
| `REPORT_STALE_DAYS` | `30` | Log envs idle this long as "verify + `ci-teardown`". | Marginally (housekeeping of preview envs). |
| `AUTO_REAP_STALE_DAYS` | `0` | `0` = report only; `>0` = auto-teardown after N idle days. | Yes if `>0` — abandoned preview envs get torn down. |

**Docker context:**

| Key | Default | Controls | Affects authors? |
|---|---|---|---|
| `DOCKER_HOST` | `unix:///run/user/__UID__/docker.sock` | Targets the rootless docker daemon (`install.sh` fills `__UID__`). Exported by `run-group.sh`, `prune-disk`, `reap-containers`, `ci-status`. | No. |

**Trusted branches (declared-but-unused):**

| Key | Default | Status |
|---|---|---|
| `TRUSTED_BRANCHES` | *(unset)* | Consumed only by `is_trusted_branch()` in `bin/lib.sh`, which is **never called**. Not in the sample config; effectively dead. Don't rely on it. |

**Operator-global SMTP fallback file** — `/etc/cicd-runner/notify.env` (template
`etc/notify.env.sample`): holds the same keys as §12.3/§12.4 as a default for repos that don't ship
their own SMTP creds. **Operator-only**; per-repo `ci/secrets.enc.yaml` overrides it key-by-key.

### (e) Bootstrap / wrapper env vars (rarely relevant to authors)

These are read by host scripts at install/invoke time, not by jobs. Listed for completeness:

| Var | Where | Default | Meaning |
|---|---|---|---|
| `CICD_BASE` | every host script | `/home/cicd-runner/runner` | Install root used to locate `bin/lib.sh` + config before `runner.conf` is loaded. |
| `CICD_CONF` | `bin/lib.sh` `cicd_load_config` | *(unset)* | Explicit override path to `runner.conf` (highest precedence in the search order). |
| `CICD_RUNNER_USER` | `post-receive`, `git/ci-job` | `cicd-runner` | Runner user the git side `sudo`s to. |
| `CICD_RUNNER_BIN` | `git/ci-job` | `/home/<user>/runner/bin` | Where `ci-job` proxies read commands. |
| `CICD_NOTIFY_ENV` | `lib/cicd.sh` → `notify-email` | per-run decrypted secrets, else `/etc/cicd-runner/notify.env` | Path the mailer reads SMTP creds from (this is the mechanism that delivers per-repo secrets to the host-side mailer — §12.2). |
| `RUNNER_BASE_OVERRIDE` | `install.sh` | `$HOME/runner` | Override install base at setup time. |
| `GIT_USER` | `update-runner.sh` | `git` | Gitolite user for the self-update flow. |
| `BRANCH` | `update-runner.sh` | `main` | Branch the updater archives the runner from. |
| `CICD_AGE_ENC` | `bin/unlock-ci` | `$CICD_BASE/etc/age-key.gpg` | Optional gpg-at-rest blob holding the age key. |
| `GPG_TTY` | `bin/unlock-ci` | `$(tty)` | TTY for an interactive gpg prompt when unlocking. |
| `CICD_TOOLS_DIR` | `bin/fetch-tools.sh` | `$HOME/.local/bin` | Install dir for the stack's pinned tools (sops/yq/age/duckdb). |
| `CIJOB_POLL` / `CIJOB_POLL_MAX` | `git/ci-job` watch | `2` / `300` | `--watch` poll interval (s) and max polls before it stops watching. Handy if you script around `ci-job run --watch`. |
| `CI_STATUS_RECENT` | `bin/ci-status` | `12` | Number of recent runs shown by `ci-job status`. |
| `NO_COLOR` / `CLICOLOR_FORCE` | `bin/ci-status` | *(unset)* | Standard color-off / force-color toggles for `ci-job status` output. |
