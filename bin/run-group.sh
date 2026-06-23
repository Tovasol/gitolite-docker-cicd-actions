#!/usr/bin/env bash
# run-group.sh <repo> <branch> [event newrev oldrev pusher]
# Per-group serialized runner, runs as the CICD-RUNNER user. ARCHIVE-PUSH model
# (DESIGN §31): the git hook delivers the source tree as a tar via cicd-ingest; the
# runner has ZERO repo access. Source comes from incoming/<sha>.tar; changed-file
# list (for path filters) from incoming/<sha>.changed (computed by the hook).
# Concurrency throttling, wall-clock timeout, hardened rootless docker run, dependency
# caching, sops secrets, ephemeral-env create/update/teardown. No preserve-ref.
set -uo pipefail   # NOT -e: errors handled explicitly so one job can't abort the loop

CICD_BASE="${CICD_BASE:-/home/cicd-runner/runner}"
# shellcheck disable=SC1090
. "$CICD_BASE/bin/lib.sh"                       # function library — no side effects on source

# Source-guard: tests can `source run-group.sh` to unit-test its functions. When sourced
# (BASH_SOURCE != $0) we define functions only and skip config/arg-parse/redirect/main.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then _CICD_MAIN=1; else _CICD_MAIN=0; fi

# globals referenced by functions — placeholdered for set -u safety when sourced; the
# real values are computed below only when executed (a test sets what it needs).
repo="" branch="" group="" slug="" Q="" RUNS="" ENVS="" INC="" CACHE="${CICD_BASE}/cache"
ZERO=0000000000000000000000000000000000000000
META_repo="" META_branch="" META_job="" META_event="" META_sha="" META_pusher="" META_start="" META_startns=0

if [ "$_CICD_MAIN" = 1 ]; then
  cicd_load_config || exit 1
  repo="$1"; branch="$2"
  group="$repo/$branch"
  slug="$(slugify "$branch")"
  Q="$RUNNER_BASE/queue/$group"
  # Flat, meta-driven runs (DESIGN §3): runs/<repo…>/<ts>-<sha8>-<job>/ — branch+job live
  # in meta.json (the truth), NOT in the path; the slash-free leaf anchors the repo.
  RUNS="$RUNNER_BASE/runs/$repo"
  ENVS="$RUNNER_BASE/envs/$repo/$slug"
  CACHE="$RUNNER_BASE/cache"                  # GLOBAL cache, shared all repos (§32)
  INC="$RUNNER_BASE/incoming/$group"          # cicd-ingest drops <sha>.tar + <sha>.changed
  export SOPS_AGE_KEY_FILE
  [ -n "${DOCKER_HOST:-}" ] && export DOCKER_HOST
  # detached (no tty, via the hook's setsid+sudo) -> log to the runner log
  [ -t 1 ] || exec >>"$RUNNER_BASE/runner.log" 2>&1
  mkdir -p "$Q" "$RUNS" "$CACHE"
fi

# Static default cache env block (DESIGN §32): points every common package manager's
# cache into the one global /cache mount. NOT logic — just conventional env names; a
# tool that isn't used ignores its var; unknown tools use XDG_CACHE_HOME / CI_CACHE_DIR.
CACHE_ENV=(
  -e CI_CACHE_DIR=/cache
  -e XDG_CACHE_HOME=/cache/xdg -e XDG_DATA_HOME=/cache/xdg-data
  -e npm_config_cache=/cache/npm
  -e YARN_CACHE_FOLDER=/cache/yarn
  -e pnpm_config_store_dir=/cache/pnpm/store -e pnpm_config_cache_dir=/cache/pnpm/cache
  -e BUN_INSTALL_CACHE_DIR=/cache/bun
  -e PIP_CACHE_DIR=/cache/pip -e POETRY_CACHE_DIR=/cache/poetry
  -e UV_CACHE_DIR=/cache/uv -e PIPENV_CACHE_DIR=/cache/pipenv
  -e COMPOSER_CACHE_DIR=/cache/composer
  -e GOMODCACHE=/cache/go/mod -e GOCACHE=/cache/go/build
  -e CARGO_HOME=/cache/cargo
  -e BUNDLE_PATH=/cache/bundle -e BUNDLE_USER_CACHE=/cache/bundle/cache
  -e NUGET_PACKAGES=/cache/nuget
  -e GRADLE_USER_HOME=/cache/gradle -e "MAVEN_ARGS=-Dmaven.repo.local=/cache/maven"
  -e DENO_DIR=/cache/deno -e MIX_HOME=/cache/mix -e HEX_HOME=/cache/hex
)

if [ "$_CICD_MAIN" = 1 ]; then
  # called with event args (reap-envs / ci-recover / ci-teardown)? record the target.
  if [ -n "${3:-}" ]; then
    printf '%s %s %s %s\n' "$3" "${4:-}" "${5:-}" "${6:-unknown}" > "$Q/target.tmp"
    mv -f "$Q/target.tmp" "$Q/target"
  fi
  # ---- per-group lock: if another run-group holds it, exit (it will coalesce) ----
  exec 9>>"$Q/group.lock"
  flock -n 9 || { log "$group already running; exit"; exit 0; }
  acquire_slot                                # global slot, held until process exits
  trap ':' EXIT                               # slot/lock fds auto-release on exit
fi

src_sha() { [ "$1" = delete ] && printf '%s' "$3" || printf '%s' "$2"; }  # event new old

# Create a unique, slash-free run dir runs/<repo>/<ts>-<sha8>-<job> (atomic via mkdir;
# collision on same-second/sha/job retrigger -> -1, -2… suffix). Echoes the dir.
make_rundir() {  # <ts> <sha8> <job>
  local base="$RUNS/$1-$2-$3" d="$RUNS/$1-$2-$3" n=1
  mkdir -p "$RUNS"
  until mkdir "$d" 2>/dev/null; do d="$base-$n"; n=$((n + 1)); done
  printf '%s' "$d"
}

# JSON string escape (backslash + doublequote) for the hand-rolled meta writer.
jesc() { printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Fat, single-line meta.json — the SOURCE OF TRUTH for a run (path is a dumb bucket).
# Identity (META_*) is set once per run by the caller; this writes/overwrites the line
# with the dynamic status/timing. NDJSON-friendly: one object, one line, sq/jq/sqlite
# all consume `find runs -name meta.json -exec cat {} +`. schema:1 = additive-only.
emit_meta() {  # <file> <status> [exit] [end_iso] [end_ns] [dur]  (last 4 optional)
  local f="$1" status="$2" ex="${3:-}" eiso="${4:-}" ens="${5:-}" dur="${6:-}" end_j ens_j dur_j ex_j
  [ -n "$eiso" ] && end_j="\"$(jesc "$eiso")\"" || end_j=null
  [ -n "$ens" ]  && ens_j="$ens" || ens_j=null
  [ -n "$dur" ]  && dur_j="$dur" || dur_j=null
  [ -n "$ex" ]   && ex_j="$ex"   || ex_j=null
  printf '{"schema":1,"repo":"%s","branch":"%s","job":"%s","event":"%s","sha":"%s","pusher":"%s","start":"%s","start_ns":%s,"status":"%s","end":%s,"end_ns":%s,"duration_s":%s,"exit":%s}\n' \
    "$(jesc "$META_repo")" "$(jesc "$META_branch")" "$(jesc "$META_job")" "$(jesc "$META_event")" \
    "$(jesc "$META_sha")" "$(jesc "$META_pusher")" "$(jesc "$META_start")" "${META_startns:-0}" \
    "$(jesc "$status")" "$end_j" "$ens_j" "$dur_j" "$ex_j" > "$f"
}

# Readiness gates (deferred-recovery, §33). When the environment can't run a job
# (docker down, or key not loaded for a secret-using job), DEFER it: leave the target
# pending + keep the incoming tar, so it auto-runs once ready (ci-recover / unlock-ci).
# Distinct from a CODE failure (build errored) which is recorded + does not loop.
ready_docker() { docker info >/dev/null 2>&1; }
key_loaded()   { [ -s "${SOPS_AGE_KEY_FILE:-}" ]; }

# Run one matched job inside a hardened, throwaway container.
execute_job() {  # <job> <event> <newrev> <pusher> <workdir> <manifest>
  local job="$1" event="$2" newrev="$3" pusher="$4" work="$5" manifest="$6"
  local image timeout mem pids network runcmd ts dir name envfile rc outdir status_word
  local start_iso start_ns end_iso end_ns dur
  image="$(yq_str "$manifest" ".jobs.\"$job\".image")";     image="${image:-$DEFAULT_IMAGE}"
  timeout="$(yq_str "$manifest" ".jobs.\"$job\".timeout")"; timeout="${timeout:-$DEFAULT_TIMEOUT}"
  mem="$(yq_str "$manifest" ".jobs.\"$job\".memory")";      mem="${mem:-$DEFAULT_MEMORY}"
  pids="$(yq_str "$manifest" ".jobs.\"$job\".pids")";       pids="${pids:-$DEFAULT_PIDS}"
  network="$(yq_str "$manifest" ".jobs.\"$job\".network")"; network="${network:-$DEFAULT_NETWORK}"
  runcmd="$(yq_str "$manifest" ".jobs.\"$job\".run")"
  [ -n "$runcmd" ] || { log "$group/$job: no run: command, skip"; return 0; }
  local limits=()
  [ "${RESOURCE_LIMITS:-1}" = "1" ] && limits=(--pids-limit "$pids" --memory "$mem")
  # custom per-job env (.jobs.<job>.env): plaintext K=V injected as -e. Placed AFTER
  # CI_*/cache so it can override them (by design), BEFORE the secrets --env-file so a
  # secret still wins. See DESIGN §4 "Custom job env".
  local jenv=() ek ev
  for ek in $(yq_keys "$manifest" ".jobs.\"$job\".env"); do
    ev="$(yq_str "$manifest" ".jobs.\"$job\".env.\"$ek\"")"
    jenv+=(-e "$ek=$ev")
  done
  # retry + notify live in the script via /cicd/lib.sh; runner owns safety + delivery.

  ts="$(date -u +%Y%m%dT%H%M%SZ)"; start_iso="$(_ts)"; start_ns="$(date +%s%N)"
  dir="$(make_rundir "$ts" "${newrev:0:8}" "$job")"
  name="cicd-$(printf '%s' "$group-$job" | tr -c 'a-zA-Z0-9_.-' '-')-$ts"
  META_repo="$repo"; META_branch="$branch"; META_job="$job"; META_event="$event"
  META_sha="$newrev"; META_pusher="$pusher"; META_start="$start_iso"; META_startns="$start_ns"
  emit_meta "$dir/meta.json" running

  envfile=""
  if [ -f "$work/ci/secrets.enc.yaml" ]; then
    envfile="$(mktemp -p "${SHM_DIR:-/dev/shm}" cicd.env.XXXXXX)"
    if ! sops -d --output-type dotenv "$work/ci/secrets.enc.yaml" > "$envfile" 2>"$dir/secrets.err"; then
      end_ns="$(date +%s%N)"; dur=$(( (end_ns - start_ns) / 1000000000 ))
      emit_meta "$dir/meta.json" secrets-decrypt-failed 1 "$(_ts)" "$end_ns" "$dur"; rm -f "$envfile"
      notify_failure "$group/$job" secrets "$dir/output.log"
      log "$group/$job: secret decrypt failed (key loaded? run unlock-ci) — see $dir/secrets.err"
      return 1
    fi
    rm -f "$dir/secrets.err"
  fi

  outdir="$dir/cicd-out"; mkdir -p "$outdir"
  {
    echo "# event=$event sha=$newrev branch=$branch"
    echo "docker run --rm --init --name $name --cap-drop ALL --security-opt no-new-privileges \\"
    echo "  --network $network -e CI_BRANCH=$branch -e CI_BRANCH_SLUG=$slug -e CI_SHA=$newrev \\"
    echo "  -v <workspace>:/work -w /work ${envfile:+--env-file <decrypted>} $image sh -c '$runcmd'"
  } > "$dir/cmd"

  log "$group/$job: start image=$image timeout=$timeout net=$network"
  timeout --kill-after=30 "$timeout" \
    docker run --rm --init --name "$name" \
      --cap-drop ALL --security-opt no-new-privileges \
      "${limits[@]}" --network "$network" \
      --label cicd=1 --label "cicd.group=$group" \
      -e CI_EVENT="$event" -e CI_REPO="$repo" -e CI_BRANCH="$branch" \
      -e CI_BRANCH_SLUG="$slug" -e CI_SHA="$newrev" -e CI_PUSHER="$pusher" \
      "${CACHE_ENV[@]}" \
      "${jenv[@]}" \
      -e CI_ENV_DIR=/envstate -v "$ENVS:/envstate" \
      -e CI_OUTBOX=/cicd/out/notify \
      -v "$RUNNER_BASE/lib/cicd.sh:/cicd/lib.sh:ro" -v "$outdir:/cicd/out" \
      -v "$CACHE:/cache" -v "$work:/work" -w /work \
      ${envfile:+--env-file "$envfile"} \
      "$image" sh -c "$runcmd" \
      >>"$dir/output.log" 2>&1
  rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then docker rm -f "$name" >/dev/null 2>&1 || true; rc=124; fi
  if [ "$rc" -eq 124 ]; then status_word=timeout; else status_word="exit:$rc"; fi
  end_iso="$(_ts)"; end_ns="$(date +%s%N)"; dur=$(( (end_ns - start_ns) / 1000000000 ))
  emit_meta "$dir/meta.json" "$status_word" "$rc" "$end_iso" "$end_ns" "$dur"
  cicd_flush_outbox "$outdir/notify" "$rc" "$dir" "$group/$job" "$envfile"
  [ "$rc" -eq 0 ] && log "$group/$job: done" || log "$group/$job: FAILED $status_word"
  [ -n "$envfile" ] && rm -f "$envfile"
  return "$rc"
}

# Persist what teardown needs, so a delete (hook OR reaper) can run without repo access.
persist_env_for_teardown() {  # <work> <manifest> <srctar>
  local work="$1" manifest="$2" srctar="$3" tjob tscript timage
  for tjob in $(yq_keys "$manifest" ".jobs"); do
    [ -n "$(yq_str "$manifest" ".jobs.\"$tjob\".on.delete")" ] || continue
    tscript="$(yq_str "$manifest" ".jobs.\"$tjob\".run")"
    timage="$(yq_str "$manifest" ".jobs.\"$tjob\".image")"; timage="${timage:-$DEFAULT_IMAGE}"
    mkdir -p "$ENVS"
    printf '%s' "$branch"  > "$ENVS/branch"         # EXACT branch (recoverable; §31)
    printf '%s\n' "$tscript" > "$ENVS/teardown.cmd"
    printf '%s\n' "$timage"  > "$ENVS/teardown.image"
    printf '{"repo":"%s","branch":"%s","slug":"%s","saved":"%s"}\n' \
      "$repo" "$branch" "$slug" "$(_ts)" > "$ENVS/meta.json"
    [ -n "$srctar" ] && [ -f "$srctar" ] && cp -f "$srctar" "$ENVS/source.tar"  # latest tree for teardown
    log "$group: persisted teardown plan for $slug (job=$tjob)"
    return 0
  done
}

find_delete_job() {  # <manifest> -> first job whose on.delete matches $branch
  local manifest="$1" job inc ign
  for job in $(yq_keys "$manifest" ".jobs"); do
    [ -n "$(yq_str "$manifest" ".jobs.\"$job\".on.delete")" ] || continue
    inc="$(yq_list "$manifest" ".jobs.\"$job\".on.delete.branches")"
    ign="$(yq_list "$manifest" ".jobs.\"$job\".on.delete.\"branches-ignore\"")"
    branch_matches "$branch" "$inc" "$ign" || continue
    printf '%s\n' "$job"; return 0
  done
  return 1
}

run_teardown() {  # <oldrev> <pusher>
  local oldrev="$1" pusher="$2" ts dir name envfile rc start_iso start_ns end_ns dur
  local work="" manifest="" tjob="" image runcmd mountwork outdir srctar secsrc
  ts="$(date -u +%Y%m%dT%H%M%SZ)"; start_iso="$(_ts)"; start_ns="$(date +%s%N)"
  dir="$(make_rundir "$ts" "${oldrev:0:8}" teardown)"
  name="cicd-teardown-$(printf '%s' "$group" | tr -c 'a-zA-Z0-9_.-' '-')-$ts"
  META_repo="$repo"; META_branch="$branch"; META_job="teardown"; META_event="delete"
  META_sha="$oldrev"; META_pusher="$pusher"; META_start="$start_iso"; META_startns="$start_ns"
  emit_meta "$dir/meta.json" running

  # --- source tree: hook-delivered incoming/<oldrev>.tar -> else persisted env source.tar ---
  srctar=""
  [ "$oldrev" != "$ZERO" ] && [ -f "$INC/$oldrev.tar" ] && srctar="$INC/$oldrev.tar"
  [ -z "$srctar" ] && [ -f "$ENVS/source.tar" ] && srctar="$ENVS/source.tar"
  if [ -n "$srctar" ]; then
    work="$(mktemp -d)"; tar -x -C "$work" -f "$srctar" 2>/dev/null || { rm -rf "$work"; work=""; }
  fi

  if [ -n "$work" ] && [ -f "$work/.gitolite/ci.yml" ]; then
    manifest="$work/.gitolite/ci.yml"
    if tjob="$(find_delete_job "$manifest")"; then
      image="$(yq_str "$manifest" ".jobs.\"$tjob\".image")"; image="${image:-$DEFAULT_IMAGE}"
      runcmd="$(yq_str "$manifest" ".jobs.\"$tjob\".run")"
      mountwork=(-v "$work:/work" -w /work)
    fi
  fi
  if [ -z "${runcmd:-}" ] && [ -f "$ENVS/teardown.cmd" ]; then   # minimal fallback
    image="$(cat "$ENVS/teardown.image" 2>/dev/null)"; image="${image:-$DEFAULT_IMAGE}"
    runcmd="$(cat "$ENVS/teardown.cmd")"
    mountwork=(-w /envstate)
  fi
  if [ -z "${runcmd:-}" ]; then
    end_ns="$(date +%s%N)"; dur=$(( (end_ns - start_ns) / 1000000000 ))
    emit_meta "$dir/meta.json" exit:0 0 "$(_ts)" "$end_ns" "$dur"
    [ -n "$work" ] && rm -rf "$work"
    log "$group: nothing to tear down for $slug"; return 0
  fi

  secsrc=""
  [ -n "$work" ] && [ -f "$work/ci/secrets.enc.yaml" ] && secsrc="$work/ci/secrets.enc.yaml"
  # DEFER teardown if it needs secrets but the key isn't loaded — don't mark it failed
  # (env-not-ready ≠ code failure); retry once the key is posted.
  if [ -n "$secsrc" ] && ! key_loaded; then
    log "$group: teardown needs secrets, key not loaded — DEFERRING $slug (retry after unlock-ci)"
    [ -n "$work" ] && rm -rf "$work"; return 2
  fi
  envfile=""
  if [ -n "$secsrc" ]; then
    envfile="$(mktemp -p "${SHM_DIR:-/dev/shm}" cicd.env.XXXXXX)"
    sops -d --output-type dotenv "$secsrc" > "$envfile" 2>/dev/null || { rm -f "$envfile"; envfile=""; }
  fi

  mkdir -p "$ENVS"; outdir="$dir/cicd-out"; mkdir -p "$outdir"
  date -u +%s > "$ENVS/last_attempt"
  local tlimits=()
  [ "${RESOURCE_LIMITS:-1}" = "1" ] && tlimits=(--pids-limit "$DEFAULT_PIDS" --memory "$DEFAULT_MEMORY")
  log "$group: teardown $slug (mode=$([ -n "$work" ] && echo full-tree || echo minimal))"
  timeout --kill-after=30 "${DEFAULT_TIMEOUT}" \
    docker run --rm --init --name "$name" \
      --cap-drop ALL --security-opt no-new-privileges \
      "${tlimits[@]}" --network "$DEFAULT_NETWORK" \
      --label cicd=1 --label "cicd.group=$group" \
      -e CI_EVENT=delete -e CI_REPO="$repo" -e CI_BRANCH="$branch" \
      -e CI_BRANCH_SLUG="$slug" -e CI_PUSHER="$pusher" \
      -e CI_ENV_DIR=/envstate -v "$ENVS:/envstate" \
      -e CI_OUTBOX=/cicd/out/notify \
      -v "$RUNNER_BASE/lib/cicd.sh:/cicd/lib.sh:ro" -v "$outdir:/cicd/out" \
      "${mountwork[@]}" \
      ${envfile:+--env-file "$envfile"} \
      "$image" sh -c "$runcmd" \
      >>"$dir/output.log" 2>&1
  rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then docker rm -f "$name" >/dev/null 2>&1 || true; rc=1; fi
  end_ns="$(date +%s%N)"; dur=$(( (end_ns - start_ns) / 1000000000 ))
  emit_meta "$dir/meta.json" "exit:$rc" "$rc" "$(_ts)" "$end_ns" "$dur"

  if [ "$rc" -eq 0 ]; then
    cicd_flush_outbox "$outdir/notify" 0 "$dir" "$group teardown" "$envfile"
    rm -rf "$ENVS"                                    # env destroyed; state + source.tar gone
    [ -n "$srctar" ] && [ "$srctar" = "$INC/$oldrev.tar" ] && rm -f "$INC/$oldrev.tar" "$INC/$oldrev.changed"
    log "$group: teardown done"
  else
    # KEEP the tree + state for operator retry — copy the delivered tar into the env dir.
    [ -n "$srctar" ] && cp -f "$srctar" "$ENVS/source.tar" 2>/dev/null || true
    printf '%s' "$branch" > "$ENVS/branch"
    printf 'exit:%s @ %s\nlog: %s\n' "$rc" "$(_ts)" "$dir/output.log" > "$ENVS/teardown-failed"
    cicd_flush_outbox "$outdir/notify" "$rc" "$dir" "$group teardown NEEDS OPERATOR (ci-teardown)" "$envfile"
    log "$group: teardown FAILED ($rc) — source+state KEPT, no auto-retry"
  fi
  [ -n "$envfile" ] && rm -f "$envfile"
  [ -n "$work" ] && rm -rf "$work"
  return "$rc"
}

# Process one create/push target from the delivered tar.
process_build() {  # <event> <newrev> <oldrev> <pusher>
  local event="$1" newrev="$2" oldrev="$3" pusher="$4"
  local work manifest changed any=1 srctar
  srctar="$INC/$newrev.tar"
  [ -f "$srctar" ] || { log "$group: no delivered source for $newrev (incoming missing)"; return 1; }
  work="$(mktemp -d)"
  if ! tar -x -C "$work" -f "$srctar" 2>/dev/null; then
    log "$group: extract $srctar failed"; rm -rf "$work"; return 1
  fi
  manifest="$work/.gitolite/ci.yml"
  [ -f "$manifest" ] || { log "$group: no .gitolite/ci.yml at $newrev"; rm -rf "$work"; return 0; }
  changed="$(cat "$INC/$newrev.changed" 2>/dev/null)"   # computed by the hook (git side)

  # DEFER (don't consume) if this repo needs secrets but the key isn't loaded — e.g.
  # post-reboot before unlock-ci. Keep incoming/<sha>.tar; ci-recover retries when ready.
  if [ -f "$work/ci/secrets.enc.yaml" ] && ! key_loaded; then
    log "$group: key not loaded + repo has secrets — DEFERRING $newrev (retry after unlock-ci)"
    rm -rf "$work"; return 2
  fi

  local job inc ign pinc pign
  for job in $(yq_keys "$manifest" ".jobs"); do
    [ -n "$(yq_str "$manifest" ".jobs.\"$job\".on.$event")" ] || continue
    inc="$(yq_list "$manifest" ".jobs.\"$job\".on.$event.branches")"
    ign="$(yq_list "$manifest" ".jobs.\"$job\".on.$event.\"branches-ignore\"")"
    branch_matches "$branch" "$inc" "$ign" || { log "$group/$job: branch filtered"; continue; }
    if [ "$event" = "push" ] || [ "$event" = "create" ]; then
      pinc="$(yq_list "$manifest" ".jobs.\"$job\".on.$event.paths")"
      pign="$(yq_list "$manifest" ".jobs.\"$job\".on.$event.\"paths-ignore\"")"
      if [ -n "$pinc$pign" ] && ! paths_match "$changed" "$pinc" "$pign"; then
        log "$group/$job: paths filtered"; continue
      fi
    fi
    any=0
    execute_job "$job" "$event" "$newrev" "$pusher" "$work" "$manifest"
  done

  persist_env_for_teardown "$work" "$manifest" "$srctar"   # branch + source.tar for future teardown
  [ "$any" -ne 0 ] && log "$group: no jobs matched $event on $branch"
  rm -rf "$work"
  rm -f "$INC/$newrev.tar" "$INC/$newrev.changed"          # consumed
  return 0
}

# ---- coalescing main loop ---------------------------------------------------
if [ "$_CICD_MAIN" = 1 ]; then
last=""; rc=0
while :; do
  [ -f "$Q/target" ] || break
  target="$(cat "$Q/target")"
  [ "$target" = "$last" ] && break
  read -r event newrev oldrev pusher <<< "$target"
  pusher="${pusher:-unknown}"

  # readiness gate: docker must be up to run ANYTHING (post-reboot / docker-down window).
  # Defer = leave target pending, don't advance `last`; ci-recover / unlock-ci retries.
  if ! ready_docker; then
    log "$group: docker not ready — DEFERRING ($target); ci-recover/unlock-ci will retry"
    break
  fi

  rc=0
  case "$event" in
    delete) run_teardown "$oldrev" "$pusher"; rc=$? ;;
    create|push)
      if [ "${DELETE_SUPERSEDES:-1}" = "1" ]; then
        nxt="$(cat "$Q/target")"; read -r nev _ _ _ <<< "$nxt"
        [ "$nev" = "delete" ] && { last=""; continue; }
      fi
      process_build "$event" "$newrev" "$oldrev" "$pusher"; rc=$? ;;
    *) log "$group: unknown event '$event'" ;;
  esac

  # rc==2 → deferred (env not ready): leave pending, retry later (do NOT advance last)
  [ "$rc" = 2 ] && { log "$group: deferred ($target) — env not ready"; break; }
  last="$target"
done

# prune stale incoming tars for this group (intermediates skipped by coalesce)
find "$INC" -maxdepth 1 -type f -name '*.tar' -mmin +60 -delete 2>/dev/null || true
find "$INC" -maxdepth 1 -type f -name '*.changed' -mmin +60 -delete 2>/dev/null || true

printf '%s\n' "$last" > "$Q/last"
log "$group: idle"
fi  # _CICD_MAIN
