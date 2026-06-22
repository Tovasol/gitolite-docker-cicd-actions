# CI Runner — Scaling, Capacity & Lifetime Cost

> Prescriptive analysis: where bytes/inodes go, what's bounded vs unbounded, what
> breaks first at scale, and whether this is a solid investment. Companion to
> `CI-RUNNER-DESIGN.md` (the *why*) and `CI-RUNNER-SOP.md` (the *how*).

Last updated: 2026-06-22

> **⚠ UPDATE (DESIGN §32): the cache analysis below is revised.** Sections 1–8 were
> written for a **per-repo** npm cache (the ~105 GB unbounded monster). That's been
> replaced by **ONE global, multi-ecosystem, content-addressed cache** + a reaper
> (now implemented in `prune-disk`). Revised figures:
> - Cache @ 300 repos: **~5–20 GB** (deduped union of distinct deps, size-capped via
>   `CACHE_MAX_GB`), **not** ~105 GB. It is now a **bounded** vector, not the #1 risk.
> - Total @ 300 repos: **~40–50 GB** (was ~125 GB). Sizing rule becomes
>   `disk ≈ 20 GB cache-cap + daily_runs×30×0.25 MB + active_envs×10 MB + 12 GB docker`
>   → **a 100 GB disk comfortably holds ~300 repos.**
> - The "#1 issue / one cache-eviction cron" action item below is **DONE** (global
>   cache + `prune-disk` reaper). The remaining ceilings (throughput, no-DB queries)
>   stand. Read the per-repo numbers below as the pre-§32 worst case.

---

## 1. On-disk layout, annotated by growth behavior

```
/home/cicd-runner/runner/   ($RUNNER_BASE)
│
├── bin/  lib/  etc/  slots/        ███ FIXED      ~1 MB total, never grows
│
├── queue/<repo>/<branch>/          ░░░ TINY       target+last+lock, ~bytes per active group
│       target  last  group.lock
│
├── incoming/<repo>/<branch>/       ▒▒▒ TRANSIENT  deleted after each run (+1d reaper backstop)
│       <sha>.tar  <sha>.changed         peak = (in-flight pushes) × (repo tree size)
│
├── runs/<repo>/<branch>/<ts>-<sha>-<job>/   ▓▓▓ BOUNDED by LOG_RETENTION_DAYS
│       status  output.log  cmd  meta.json  cicd-out/notify     (~250 KB/run, ~7 inodes/run)
│       latest -> …                              cumulative within the retention window only
│
├── envs/<repo>/<slug>/             ▓▓▓ BOUNDED by # ACTIVE ephemeral branches (deleted on teardown)
│       branch  meta.json  state  source.tar  teardown.cmd/image  ci/   (~10 MB/env, source.tar dominates)
│
└── cache/<repo>/                   ███ UNBOUNDED ⚠  the ONLY unmanaged growth vector
        npm/   (cacache: every dep tarball ever fetched, content-addressed)
        nm/    (node_modules result tarballs, one per lockfile hash)        ~350 MB/repo, grows forever

PLUS host-level docker (rootless):
~/.local/share/docker/              ▓▓▓ BOUNDED by prune-disk (keep-storage 10g + image prune)
        images + buildkit cache + container layers      ~1–12 GB, capped
```

Legend: ███ fixed/unbounded · ▓▓▓ bounded (retention/count/cap) · ▒▒▒ transient · ░░░ negligible

---

## 2. The growth taxonomy (the whole story in one table)

| Path | Grows with | Bounded by | At 300 repos | Risk |
|---|---|---|---|---|
| bin/lib/etc/slots | nothing | — | ~1 MB | none |
| queue/ | active groups | active groups | <5 MB | none |
| incoming/ | in-flight pushes | deleted post-run | <1 GB peak | none |
| **runs/** | run rate | **LOG_RETENTION_DAYS** | ~7 GB | tune retention |
| **envs/** | active branches | teardown | ~1 GB | none (source.tar) |
| **cache/** | repos × deps | **NOTHING (gap)** | **~105 GB** | ⚠ **#1 issue** |
| docker | builds/images | **prune-disk cap** | ~10 GB | none |

**Headline: everything is bounded except the per-repo dependency cache.** It is
~84% of disk at scale and the only thing that grows forever without a reaper.

---

## 3. Capacity model (numbers you can plan against)

Per-unit footprints (node/site project; YMMV):
- **run:** ~250 KB (mostly `output.log`), ~7 inodes
- **repo cache:** ~350 MB (npm cacache ~150 MB + nm tarballs ~200 MB)
- **active env:** ~10 MB (`source.tar` = the tree)
- **docker:** ~1–12 GB host-wide (shared base images + capped build cache)

### Scale scenarios (30-day log retention)

| | repos | runs/day/repo | runs/ | cache/ | envs/ | docker | **TOTAL** | inodes (runs) |
|---|---|---|---|---|---|---|---|---|
| **Small** | 10 | 1 | 75 MB | 3.5 GB | 55 MB | ~2 GB | **~6 GB** | ~2 k |
| **Medium** | 100 | 2 | 1.5 GB | 35 GB | 0.3 GB | ~8 GB | **~45 GB** | ~42 k |
| **Large** | 300 | 3 | 6.8 GB | **105 GB** | 1.1 GB | ~10 GB | **~125 GB** | ~190 k |

At "Large," **cache is 84% of total**. Runs/docker/envs together are ~15%.
Inode count (~190 k) is a non-issue on ext4/xfs (millions available).

### Sizing rule of thumb
```
disk ≈ (repos × 0.35 GB cache) + (daily_runs × 30 × 0.25 MB) + (active_envs × 10 MB) + 12 GB docker
```
→ **A 200 GB disk comfortably holds ~300 active repos.** Cache dominates; size for it.

---

## 4. What breaks first (ranked)

1. **⚠ Dependency cache fills the disk.** `prune-disk` prunes *docker*, not the
   `cache/<repo>/{npm,nm}` trees. At ~300 repos that's ~105 GB and climbing. **Fix
   (one cron):** LRU-evict `nm/*.tar.zst` beyond N-per-repo + age, and
   `npm cache verify`/cacache GC, or a per-repo size cap. ~15 lines. **Do this
   before scaling past a few dozen repos.** (Tracked as the top open item.)
2. **Throughput ceiling — CPU/RAM, not disk.** `MAX_JOBS` slots cap concurrent
   builds. With `MAX_JOBS=4` and ~2.5 min/build → ~2,300 builds/day sustained on
   one host. 300 repos × 3 = 900/day fits. Beyond that: raise `MAX_JOBS` (if cores
   allow) or shard to a second runner host. The wall is concurrent-build
   CPU/RAM, not the runner logic.
3. **Query-ability degrades (no DB).** "All failed runs across repos" = grep the
   filesystem. Sub-second at hundreds of repos / tens of thousands of run-dirs;
   slow at millions. The filesystem-dashboard is great to ~hundreds of repos,
   then the no-DB choice costs you indexed queries (the point you'd consider a
   forge — see DESIGN §2/§11).
4. **Log size spikes.** A pathological build (MB of output) inflates `runs/`.
   Bounded by retention, but cap per-run log size if builds get chatty.

Everything else (containers, incoming, queue, envs) is self-bounding via the
existing crons + lifecycle.

---

## 5. Diagram: disk at "Large" (300 repos)

```
TOTAL ~125 GB
cache/   ████████████████████████████████████████████  105 GB  (84%)  ⚠ unbounded
docker   ████                                            10 GB  ( 8%)  capped
runs/    ███                                            6.8 GB  ( 5%)  retention-bounded
envs/    ▌                                              1.1 GB  ( 1%)  active-count-bounded
rest     ▏                                              <2 GB   ( 2%)
```
The investment decision is essentially: **"can I give this box ~150–200 GB and add
one cache-eviction cron?"** If yes, hundreds of repos are fine.

---

## 6. Lifetime management cost (OpEx)

| Activity | Frequency | Time | Notes |
|---|---|---|---|
| Onboard a repo | per repo, once | 5–15 min | drop `ci.yml` + `ci/*.sh` + secrets |
| Crons (reap/prune/cache) | set once | ~0 | self-running; verify quarterly (~15 min/qtr) |
| Per-reboot key unlock | per reboot (~monthly) | ~30 s | ONLY on the ramfs-hardened path; simple path = 0 |
| Failed-teardown triage | rare | ~5 min | `ci-teardown retry|abandon` |
| Disk watch | passive | ~0 | alert at 80%; mostly cache |
| Incident triage | ~1–2/month at scale | ~15 min | stuck build, disk, a flaky deploy |

**Steady-state OpEx at scale: ~1–2 hours/month**, dominated by incident triage +
(until automated) cache housekeeping. The crons carry the routine load. The
human-in-the-loop costs are the per-reboot unlock (if you chose hardening) and
failed-teardown retries — both rare and bounded, by deliberate design.

---

## 7. Is it a solid investment? (prescriptive verdict)

**CapEx:** already spent (the build + this design conversation). Marginal cost to
finish = the one cache-eviction cron + the live integration test.

**Where it's a clear yes:**
- Personal → small-team → **low hundreds of repos** on a single well-sized VPS
  (4+ cores, ~150–200 GB disk). Disk scales linearly and predictably (≈0.35 GB/repo
  cache + small bounded extras). OpEx is ~1–2 h/month.
- You value transparency (filesystem = dashboard), no DB/forge/blackbox, and full
  control. Nothing here you can't read in an afternoon.

**Where it stops being the right tool:**
- **Throughput:** sustained >~2 k builds/day or heavy parallelism on one host →
  shard runner hosts or raise the box. Multi-host sharding is a real (not trivial)
  extension.
- **Repo count >> hundreds / many teams:** query-ability and per-team RBAC start
  wanting a DB + UI → that's the **migration door** (DESIGN §2/§11/§15). Because
  retry/notify/logic live in portable `ci/*.sh` and the manifest is GH-Actions-
  shaped, **you graduate to Forgejo/Gitea Actions carrying the scripts unchanged** —
  you rewrite ~10-line triggers, not the pipelines. The investment is *not* a dead
  end; it's a stepping stone with an exit that preserves your work.

**The honest risk ledger:**
- ✅ Bounded by design: runs, docker, envs, incoming, queue, containers.
- ⚠ One unbounded vector (cache) — closeable with one cron; close it early.
- ⚠ Single-host throughput + no-DB query ceiling — both land around "hundreds of
  repos," both have a clean exit (more hosts / adopt a forge).
- ✅ Migration door keeps the durable asset (the `ci/*.sh` logic) portable.

**Verdict:** For the stated horizon (personal/small-scale, growing toward hundreds
of repos), this is a **solid, low-OpEx investment** — *provided* you add cache
eviction and size the disk for the cache. Its ceiling is honest and its exit is
cheap: when you outgrow a single transparent host, your pipelines move to a real
engine intact. You're buying simplicity + control now, with a paid-for off-ramp
later — not a lock-in.

---

## 8. Action items implied by this analysis
1. **Add a cache-eviction cron** (the one real gap) — LRU/age/size-cap on
   `cache/<repo>/{npm,nm}`. Highest-value scaling fix.
2. **Set `LOG_RETENTION_DAYS`** to your real audit need (default 30; lower = less disk).
3. **Size disk** ≈ `repos × 0.35 GB + 20 GB`. Alert at 80%.
4. **Pick `MAX_JOBS`** = ~cores/2 for node builds; watch queue latency.
5. Revisit forge migration when repo count or team count crosses "hundreds."
