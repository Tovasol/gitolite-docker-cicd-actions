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

If your job needs secrets:
1. Commit an encrypted file at **`ci/secrets.enc.yaml`** in your repo (sops-encrypted with the
   runner's age recipient — key management is operator-controlled and out of scope here).
2. The runner decrypts it (`sops -d --output-type dotenv`) into a tmpfs env-file and injects it
   as `--env-file`. **Each key becomes an env var** available to your `run:` script.

Author-facing contract: presence of `ci/secrets.enc.yaml` is the trigger — there is **no
`secrets:` manifest field** (the runner keys entirely off the file). If the file is present but
the age key isn't loaded on the host, the run is *deferred* (kept pending), not failed; it
auto-runs once the key is unlocked. A decrypt failure marks the run `secrets-decrypt-failed`.

> Do not invent key-management/recipient details — coordinate with the operator for how to
> encrypt against the runner's age public key.

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
```
