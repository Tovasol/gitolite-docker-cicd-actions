---
title: "The Filesystem Is the Dashboard: A Weekend Personal CI/CD"
date: 2026-06-22
tags: [ci-cd, gitolite, docker, rootless, sops, self-hosting, llm]
---

> **Title candidates** (pick your favorite):
> - *The Filesystem Is the Dashboard: A Weekend Personal CI/CD* ← my pick
> - *Bone-Simple CI/CD: A Weekend Build*
> - *No Forge, No Daemon, No Database*
> - *Push to Deploy, the Honest Way*
> - *The Weekend Personal CI/CD Build* (your original — clean, works)

I run [gitolite](https://gitolite.com/). It's a couple thousand lines of Perl that
turns SSH keys into git access control, and every bit of its state — config,
hooks, the repos themselves — is a file on disk you can `cat`. I love it for
exactly that reason: nothing is hidden.

I wanted CI/CD for it. Push to a branch, build a site, deploy to Cloudflare Pages.
The obvious move is to bolt on a real CI system. I spent an evening figuring out
why I didn't want to — and then a weekend building the thing I did want instead,
with an LLM as a relentless pair. This is that story, the design, and how to wire
it up yourself. There's a twist at the end about how I'm "distributing" it.

## What I refused

Every lightweight, market-normal CI engine is **forge-coupled**. Drone, Woodpecker
— they need a git *host* (Gitea, GitHub, GitLab) for webhooks, auth, and a UI.
Gitolite is none of those. It's SSH and files. So my options collapsed to:

- **Jenkins** — old, heavy, a plugin swamp. No.
- **A forge + its CI** (Gitea/Forgejo Actions) — genuinely nice, GitHub-Actions
  compatible. But it's a compiled binary with a database. Users, run history, logs,
  secrets all live in opaque app state. That's the *opposite* of the gitolite ethos
  I was trying to preserve.
- **Laminar** — the closest in spirit (jobs are scripts on disk). But it stores
  logs as gzip blobs *inside SQLite*, runs job scripts directly on the host with no
  sandbox, and its real value is a DAG I didn't need.

The realization that reframed everything: **there is no lightweight + transparent +
turnkey standalone CI.** It doesn't exist, because the light ones all chose to
couple to a forge to get auth and a UI cheaply. My actual requirement — transparent,
on-disk history and logs for a few independent build→deploy pipelines — is *lighter*
than a CI product, not heavier.

So: hand-roll it. The guiding principle wrote itself: **the filesystem is the
dashboard.** `ls` is run history. `cat` is logs. No database, no daemon you have to
keep alive, no blackbox. Like gitolite.

## The shape

It ends up being three thin layers:

```
git push ─▶ post-receive hook (runs as the git user)
              │  classify create/push/delete, hand off, return immediately
              ▼
            run-group.sh (runs as a separate cicd-runner user)
              │  flock per branch · global slot semaphore · match branch/path globs
              │  hardened rootless `docker run` · wall-clock timeout · logs to files
              ▼
            a throwaway container — your build/deploy script, sandboxed
```

A push fires the hook. The hook does the *minimum* and returns — the developer's
`git push` never waits on a build. The runner picks it up, checks out the commit,
reads a tiny manifest, and runs the job in a throwaway container. Everything it does
lands as plain files:

```
~/runner/runs/<repo>/<branch>/<timestamp>-<sha>-<job>/
    status        # exit:0 | timeout | …
    output.log    # the whole thing
    cmd           # the exact `docker run` — paste it to reproduce by hand
    meta.json     # who pushed, when, which sha
```

A project opts in by dropping two files in its repo: a `.gitolite/ci.yml` manifest
(triggers — GitHub-Actions-shaped `on: { push: { branches, paths } }`) and a
`ci/*.sh` script (the actual logic). The manifest is deliberately tiny and
standard-looking, so the day I outgrow this and move to real GitHub Actions, the
*scripts* port unchanged and I only rewrite a ten-line trigger file.

## The decisions that made it good

A few choices, most of them argued out with the LLM pushing back, are what keep this
from being a pile of bash:

**Rootless Docker, and two users, not one.** The runner runs builds in *rootless*
Docker — a container escape can't reach host root. And the runner is a dedicated
`cicd-runner` user, separate from gitolite's `git` user. Why bother? Because `npm
install` runs arbitrary code from the registry. A poisoned transitive dependency
executes *in your build*. If that build ran as `git`, the blast radius is your
entire SCM and its access control. As `cicd-runner`, it's contained to CI state.
Defense in depth against the supply chain, not against a malicious human.

**The runner owns mechanism; the script owns policy.** I almost added `retries:` and
`notify:` fields to the manifest. Then the LLM and I talked it through: if branching
belongs in the script, so do retry and notify. The runner mounts a tiny helper
library into every container at `/cicd/lib.sh`. Your script does the smart stuff:

```sh
. /cicd/lib.sh
trap 'rc=$?; [ $rc -eq 0 ] && notify_success "deployed $CI_SHA" \
                          || notify_error "FAILED rc=$rc"' EXIT
retry -n 3 -d 10 -- npm ci          # retry one flaky command, not the whole job
npm run build
retry -n 2 -- npx wrangler pages deploy dist --project-name=…
```

Fan-out, fan-in, rollback, conditional deploys — all just bash, because the script
is the unit of logic. The runner stays dumb. The one thing the runner keeps is
*safety*: a wall-clock timeout (a hung script can't kill itself) and the container
sandbox. **No DAG.** The moment you want job B to depend on job A as first-class
scheduled jobs, that's a real scheduler — adopt a real engine; don't rebuild one.

**Notifications go through an outbox.** `notify_*` don't send email — they append a
line to a mounted file. The runner delivers it host-side (it has `curl` and the
SMTP creds; the container has neither). The payoff: it works in any image, the
creds never enter the container, and — critically — even if the job is OOM-killed,
whatever it wrote still gets flushed, plus a backstop fires so you never miss a hard
failure. Email goes through the same Gmail App Password I already use for Plausible.

**Secrets live in the repo, encrypted, with [sops](https://getsops.io) + age.** Each
project carries its own `ci/secrets.enc.yaml`. Humans decrypt with their GPG key
(via `pass`, even on a phone); the runner decrypts with its own passphraseless `age`
key. Either works; the repo carries its config, encrypted, and only trusted
environments hold a key. The runner's key lives in a **ramfs** dir that's wiped on
reboot — so after a reboot CI is paused until a human runs `unlock-ci` and types a
GPG passphrase. Human-gated boot, by choice.

**Ephemeral preview environments, and how to tear them down.** Push `feat/foo` →
get an isolated preview deploy. Delete the branch → tear it down. The hard part: when
the branch is deleted, the ref is *gone*, and git's GC can prune the objects — so
how does teardown get the project's files? The answer turned out to be elegant: when
the delete hook fires, the objects still exist (GC runs *after* hooks), so we
instantly pin the deleted tip under a hidden ref:

```
git update-ref refs/cicd/preserve/<slug> <oldrev>
```

That 40-byte ref keeps the *entire tree* reachable until teardown checks it out,
runs, and releases it. The remote doesn't "lose the code reference" — we hold our
own. Non-blocking push, full project tree at teardown. (If teardown fails, it keeps
the ref and emails you; one retry for transient blips, then it's the operator's
problem — no infinite loops.)

**The trigger has no daemon.** I considered a listener service watching a spool
directory. But a listener can crash, and an inotify watcher *silently drops* events
that arrive while it's down. A git hook can't: `git` guarantees the hook fires,
synchronously, on every push. The push *is* the delivery. So the bridge from `git`
to `cicd-runner` is one line of sudo — stateless trigger, no liveness to babysit,
with a tiny on-disk queue + a recovery sweep as the safety net. The whole thing
stays service-less in spirit.

## Built with an LLM, honestly

I didn't write this alone, and I didn't write it by asking an LLM to "make me a
CI system." It was a long, argumentative conversation. I'd propose something; the
model would push back or surface a gotcha; we'd converge. A sampling of the actual
turns:

- I wanted to run the deploy *inside a Dockerfile*. It pointed out that's a secret
  leak and conflates build with deploy — isolation comes from the container, not
  from `docker build`. We moved to a throwaway `docker run`.
- I worried Laminar "runs CI on the host" — exposing it. We confirmed that's true,
  *and* that packaging Laminar in Docker just moves the risk to the Docker socket.
  That detour is why I ended up rootless.
- I asked "why not just run rootless Docker as the `git` user and skip the
  cross-user complexity?" Good question — and the answer (supply-chain blast radius,
  keeping the decrypt key off the SCM user) is *why* the two-user split exists. The
  "complexity" turned out to be one sudoers line.
- We discovered, mid-build, that Docker rootless can't enforce `--memory`/`--pids`
  limits without systemd — and I'm on OpenRC. Not fixable. So the runner detects it
  and omits the no-op flags rather than pretend.
- I changed my mind three times on teardown retries (one retry? none? configurable?)
  before we landed on "one retry, then notify a human."

The output: ~700 lines of readable bash across a dozen scripts, plus two documents —
a **design doc** (every decision and *why*) and an **SOP** (copy-paste runbooks). The
LLM was great at holding the whole design in its head, catching the gotcha three
steps ahead, and being a tireless rubber duck that occasionally quacks back "that's
a DAG, you said you didn't want one." It was not a vending machine. The judgment —
what to refuse, where to draw the line — was the human part.

## Wire it up

Prereq: gitolite running, and rootless Docker running as a `cicd-runner` user. Then
it's five staged steps, each verifiable before the next:

1. **Install** the runner (`./install.sh` lays down dirs + scripts, preflights deps:
   `yq`, `sops`, `age`, `flock`).
2. **Configure** — point `runner.conf` at your rootless Docker socket; set
   `RESOURCE_LIMITS=0` on OpenRC.
3. **Bridge** — install the `post-receive` hook + one sudoers line letting `git` run
   `run-group.sh` as `cicd-runner`.
4. **Smoke test** — a no-secrets job that just echoes. Push, then
   `cat runs/<repo>/main/latest/output.log`. If you see your echo, the whole chain
   works: hook → sudo → runner → container → mounted lib → log.
5. **Real deploy** — add the `age` key + `unlock-ci`, encrypt secrets with `sops`,
   swap in the deploy job. Push. Watch `runner.log`.

The full runbook (with the exact commands, the ramfs key dance, server-move and
incident playbooks) is in the SOP. The first-timer gotchas are always the same two:
a wrong `DOCKER_HOST`, or forgetting to `unlock-ci` before a secret-using job.

## How to get it: seed prompts, not a tarball

Here's the twist. I could hand you a download link. But the most honest artifact of
a project built *this* way isn't the code — it's the **design conversation**. The
code is downstream of the decisions.

So instead of (or alongside) a tarball, I'm publishing the two documents that
*generate* the system: the **design doc** and the **SOP**. Drop them into your own
LLM and say "build this for my environment." Because the design doc encodes the
*reasoning* — not just "use rootless Docker" but *why*, and what breaks if you don't
— a competent model can regenerate the whole thing, adapted to *your* init system,
*your* paths, *your* deploy target. Running systemd instead of OpenRC? The cgroup
limitation section tells the model your limits actually work; it'll keep them. Want
Podman instead of Docker? The reasoning transfers.

The repo isn't the product. **The spec is the product**, and the LLM is the
compiler. That feels like the right way to ship something built in a weekend with an
AI pair: ship the thing the AI and I actually made — the understanding — and let the
reader's AI do the typing.

(If you'd rather just run it, the code is there too. But try the seed-prompt path at
least once. It's a strange and good feeling to watch a system rebuild itself from
its own rationale.)

## Honest caveats

- **It hasn't run end-to-end against live gitolite + Docker yet** as I write this.
  The logic is unit-tested (the glob matcher, retry, fan-in, the outbox); the
  integration is "first real push is the test." I'm not going to pretend otherwise.
- **Single-tenant assumptions.** This is for *me*, on *my* box, deploying *my*
  code. The trust model leans on that. Untrusted contributors would need more.
- **OpenRC rootless = no per-container resource caps.** Documented, accepted; the
  wall-clock timeout and host OOM-killer are the backstop.
- **It is bash.** Lovingly written, tested where it counts, but bash. That's a
  feature (you can read every line) and a liability (you can write a bug in every
  line). The filesystem-as-dashboard means when it breaks, you can *see* why.

If the gitolite ethos resonates — everything on disk, nothing hidden, small enough
to hold in your head — this is what CI/CD looks like under that philosophy. Built in
a weekend, argued out with a machine, shipped as the argument itself.
