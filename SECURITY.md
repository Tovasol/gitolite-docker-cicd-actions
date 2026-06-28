# Security model

This document states, plainly, what this system protects against and what it does
**not**. Read it before deploying — most security incidents with self-hosted CI come
from assuming an isolation boundary that was never claimed.

## What this is, and who it's for

A small, hackable CI/CD runner: gitolite `post-receive` → archive-push → job in a
rootless-docker container. It is built for **one operator, or a small team that trusts
each other**, running **their own repositories** on a single host.

**It is not a multi-tenant CI platform.** If you need to run jobs for **mutually
distrusting** users or organizations, use a system designed for that (Jenkins with
per-agent isolation, GitLab runners, GitHub Actions, per-tenant VMs/k8s). Do not use
this to run untrusted third-party code next to repos whose secrets or private code you
care about.

## Trust model — the boundary

Jobs execute **untrusted repository code** (whatever is in `ci/*.sh` + the build). The
isolation around that code is **container-level**, not a hard multi-tenant boundary:

- **All jobs run as one host user** (`cicd-runner`) and share **one `/cache` volume**,
  **one docker daemon**, and **one host**. There is **no isolation between repos** at
  the host level. One repo's job can read another repo's **cached packages** in
  `/cache`, and a container escape compromises **everything**.
- **The age key decrypts every repo's secrets.** It lives in ramfs (`/run/ci-keys`),
  readable by `cicd-runner`. Anything that runs as `cicd-runner` — or escapes a
  container — can read it and therefore **all** repos' CI secrets.

**Consequence:** run only repositories you trust at a **similar level**. Adding a
collaborator with write access to any repo effectively grants them the ability to run
code as `cicd-runner` (via CI), i.e. access to the shared cache and — on escape — the
secrets of every repo. Grant repo write access accordingly.

## What it *does* defend (defense in depth)

- **Archive-push (DESIGN §31):** the `git` user archives the pushed tree and pipes it
  through a minimal sudo bridge to `cicd-ingest`. The runner has **zero git/repo
  access** — it never reads gitolite's repositories, keys, or other repos.
- **Minimal sudo bridge:** `git` may run, as `cicd-runner`, **only** `cicd-ingest`
  (write) and `ci-status`/`ci-log`/`ci-runs` (read-only, for `ci-job`). No shell.
- **gitolite-authz on `ci-job`:** run/status/log are scoped to the repos the invoking
  ssh key may access — computed from gitolite, never from user input.
- **Hardened container:** every job runs with `--cap-drop ALL`,
  `--security-opt no-new-privileges`, the default docker **seccomp** profile, `--init`
  (PID reaping), a wall-clock **timeout**, and a configurable `--network`
  (`bridge` | `none`). Under **rootless** docker, container-root maps to the
  unprivileged `cicd-runner` uid via user namespaces.
- **Secrets:** sops + age; per-repo `ci/secrets.enc.yaml` decrypted **per job** into a
  tmpfs env-file and injected via `--env-file`; ciphertext is safe to commit.
- **Opt-in CI:** the hook only acts on repos whose pushed tree contains
  `.gitolite/ci.yml`.

## Known limitations / accepted risks

These are deliberate trade-offs for a small-scale, trusted-operator tool:

1. **Shared `/cache` across repos** (same uid, default). Maximizes dedup, but `/cache`
   also holds every tool's **config/HOME** (`CARGO_HOME`, `GRADLE_USER_HOME`, npm/pip
   caches), so a malicious job can plant config (e.g. `cargo`'s `rustc-wrapper`) that runs
   **as code** in another repo's build — **lockfiles do NOT stop this** (it's not a
   package). It can also read another repo's cached packages. *Mitigation: set
   **`CACHE_ISOLATION=per-repo`** (now implemented — each repo gets its own cache subtree,
   trading dedup for isolation) when running repos you don't mutually trust; otherwise only
   run trusted repos.*
2. **Age key blast radius.** One key decrypts all repos' secrets. *Mitigation: back it
   up out-of-band (e.g. `pass`); rotate per SOP; consider per-repo recipients if you
   onboard less-trusted repos.*
3. **Resource limits require cgroups.** Rootless `--memory`/`--pids-limit` need
   cgroup v2 + systemd delegation. On OpenRC/no-cgroups hosts they are **not enforced**
   (`RESOURCE_LIMITS=0`), so a job can OOM or fork-bomb the host. *Mitigation: run on a
   cgroup-v2/systemd host, or apply ulimit fallbacks; see DESIGN §29.*
4. **Egress is allowed by default** (`network: bridge`). A job can exfiltrate anything
   it can read. *Mitigation: set `network: none` for jobs that need no internet.*
5. **Mutable base-image tags.** `image: node:lts` etc. resolve to whatever the registry
   serves. *Mitigation: pin by digest (`@sha256:…`).*
6. **Container code runs as root-in-namespace.** Mapped to an unprivileged host uid, but
   a job has root *within* its container. Escapes rely on a docker/kernel CVE; keep the
   host patched.
7. **The runner-repo deploy branch is a ROOT trust boundary.** `update-runner.sh` extracts
   that branch's tree and runs/installs it **as root**, so **whoever can push the deploy
   branch (default `release`) effectively gets root on the runner host** — by design, no
   container escape needed. *Mitigation: protect the deploy branch (admin-only) **and** set
   `UPDATE_REQUIRE_SIGNED=1` with the trusted signer's key in root's gpg keyring (the script
   then verifies the branch tip is a signed commit before any root action). Treat deploy-
   branch write access as equivalent to root.*

## Operator responsibilities

- Grant repo **write access only** to people you'd trust to run code as `cicd-runner`.
- **Protect the runner-repo deploy branch** (admin-only) and prefer `UPDATE_REQUIRE_SIGNED=1`
  — pushing it = root on the host.
- Use **lockfiles** in builds so package managers verify integrity.
- Keep the **host and docker patched** (the escape boundary).
- **Back up the age key**; know your rotation runbook (SOP §6).
- Treat job logs as potentially sensitive (a job may print secrets); see secret
  redaction in the log/notify path.

## Reporting a vulnerability

Report privately to the maintainer (do not open a public issue for an unpatched flaw).
Include affected version/commit, a reproduction, and impact.
