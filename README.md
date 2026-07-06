# cicd-runner

Bone-simple, filesystem-transparent CI/CD for gitolite + rootless docker on a
single VPS. No DB, no forge, no daemon — host bash + `docker run` + cron + flock.
The filesystem is the dashboard. Rationale: [docs/CI-RUNNER-DESIGN.md](docs/CI-RUNNER-DESIGN.md).
Operations: [docs/CI-RUNNER-SOP.md](docs/CI-RUNNER-SOP.md).

## How it works (archive-push, §31)
```
git push ──▶ post-receive (runs as git)
                 │  classify create/push/delete; git archive the tree (oldrev on delete)
                 │  pipe [base64(changed)\n][tar]  ──sudo──▶  cicd-ingest (runs as cicd-runner)
                 ▼                                              store incoming/<sha>.tar, set target, wake
            run-group.sh  (one per repo/branch)
                 │  flock per group + global slot semaphore (MAX_JOBS)
                 │  extract delivered tar ▸ read .gitolite/ci.yml ▸ match branch+path globs
                 │  (runner has ZERO repo access — git handed it exactly this tree)
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
| `post-receive` | gitolite hook (runs as git): classify event, **`git archive` the tree, pipe it through sudo to cicd-ingest** (archive-push, §31). Runner has zero repo access. |
| `cicd-ingest` | sudo target (runs as cicd-runner): receive the framed tar stream → store sha-keyed → trigger run-group |
| `run-group.sh` | the engine: concurrency, matching, docker run, timeout, secrets, envs (source from the delivered tar) |
| `lib.sh` | shared: config load, glob matching, slug, slots, notify |
| `unlock-ci` | per-reboot: GPG-decrypt age key into ramfs |
| `ci-status` | health: key loaded? docker up? recent runs, pending |
| `ci-recover` | boot sweep: re-run targets never processed |
| `reap-containers` | cron: kill leaked/dead/runaway containers, free slots |
| `reap-envs` | cron: tear down ephemeral envs whose branch is gone |
| `prune-disk` | cron: docker prune + log retention + disk guard |
| `notify-wall` | sample failure notifier (wire via `NOTIFY_CMD`) |

`lib/cicd.sh` is mounted read-only into every job at **`/cicd/lib.sh`**. Scripts
`. /cicd/lib.sh` to get `retry`, `notify_success`/`notify_error`, `wait_all`
(fan-in), `step`, `die`. Retry + notify are the SCRIPT's job, not manifest fields
(DESIGN §28). See [examples/ci/pipeline-dag.sh](examples/ci/pipeline-dag.sh) for a full fan-out/fan-in pipeline.

## Dependencies (on the VPS)
User-local in `~cicd-runner/.local/bin` (via `bin/fetch-tools.sh` — no root, no
`/usr/local`): **sops**, **yq** (mikefarah v4), **age**. The runner re-prepends
`LOCAL_BIN` to PATH so they're found under sudo.

System runtime (reasonably shared): **docker** (rootless, SOP Appendix A), **flock**
(`util-linux`, usually present), and **gpg** only for the optional encrypted-at-rest
key (SOP §2.5/§25) — the simple key path (§2.3) needs no gpg.

## Install (summary — full steps in SOP §2)
```bash
# as cicd-runner, after rootless docker works:
./install.sh
# review ~/runner/etc/runner.conf
# as root: deploy hook + one sudoers line (the bridge); as cicd-runner: crontab
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
