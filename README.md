# cicd-runner

Bone-simple, filesystem-transparent CI/CD for gitolite + rootless docker on a
single VPS. No DB, no forge, no daemon — host bash + `docker run` + cron + flock.
The filesystem is the dashboard. Rationale: `../docs/CI-RUNNER-DESIGN.md`.
Operations: `../docs/CI-RUNNER-SOP.md`.

## How it works
```
git push ──▶ post-receive (gitolite hook)
                 │  classify event (create/push/delete), write queue/<repo>/<branch>/target, wake runner
                 ▼
            run-group.sh  (one per repo/branch)
                 │  flock per group + global slot semaphore (MAX_JOBS)
                 │  checkout sha ▸ read .gitolite/ci.yml ▸ match branch+path globs
                 │  hardened `docker run` (rootless): --cap-drop ALL, no-new-privileges,
                 │     --pids-limit, --memory, wall-clock timeout, --rm --init
                 │  sops-decrypt ci/secrets.enc.yaml ▸ inject as env (key in ramfs)
                 │  logs/status/cmd/meta ▶ runs/<repo>/<branch>/<ts>-<sha>-<job>/
                 ▼
            coalesce: newest target wins; delete supersedes; teardown on branch delete
```

## Components (`bin/`)
| Script | Role |
|---|---|
| `post-receive` | gitolite hook: classify + enqueue + wake (fast, non-blocking) |
| `run-group.sh` | the engine: concurrency, matching, docker run, timeout, secrets, envs |
| `lib.sh` | shared: config load, glob matching, slug, slots, notify |
| `unlock-ci` | per-reboot: GPG-decrypt age key into ramfs |
| `ci-status` | health: key loaded? docker up? recent runs, pending |
| `ci-recover` | boot sweep: re-run targets never processed |
| `reap-containers` | cron: kill leaked/dead/runaway containers, free slots |
| `reap-envs` | cron: tear down ephemeral envs whose branch is gone |
| `prune-disk` | cron: docker prune + log retention + disk guard |
| `notify-wall` | sample failure notifier (wire via `NOTIFY_CMD`) |

## Dependencies (on the VPS)
- rootless **docker** (see SOP Appendix A), **flock** (util-linux)
- **yq** (mikefarah v4) — manifest parsing
- **sops** + **age** — secrets (SOP §2.1 / §21)
- **gpg** — unlock the runner key (SOP §3)

## Install (summary — full steps in SOP §2)
```bash
# as cicd-runner, after rootless docker works:
./install.sh
# review ~/runner/etc/runner.conf
# as root: deploy hook + system config; as cicd-runner: crontab
crontab crontab.sample
unlock-ci && ci-status
```

## Per-project opt-in (3 files in the project repo)
1. `.gitolite/ci.yml` — triggers (see `examples/.gitolite/ci.yml`)
2. `ci/*.sh` — the actual build/deploy logic (portable; survives a future move to
   GitHub/Forgejo Actions unchanged)
3. `.sops.yaml` + `ci/secrets.enc.yaml` — encrypted secrets

See `examples/` for a working production-deploy + per-branch preview + teardown set.

## Branch / path filtering (GitHub-Actions-like)
```yaml
on:
  push:
    branches: [main, "release/*"]        # globs: * within a segment, ** across /
    branches-ignore: ["wip/**"]          # optional
    paths: ["site/**"]                   # at least one changed file must match
    paths-ignore: ["**/*.md"]            # optional
  create: { branches: ["feat/*"] }       # new branch -> provision preview env
  delete: { branches: ["feat/*"] }       # deleted branch -> teardown
```

## Not included / known limits (by design)
- No DAG / inter-pipeline orchestration (DESIGN §1).
- `--env-file` secrets are visible via `docker inspect` (root-only); upgrade to the
  tmpfs file-mount pattern if needed (DESIGN §20).
- Under rootless OpenRC, `--memory`/`--pids-limit` need cgroup-v2 delegation or
  they're silently ignored (SOP Appendix A).
- Image-building jobs (`docker build` inside a job) need Buildah/Kaniko, not DinD
  (DESIGN §26). Current scope doesn't build images.
