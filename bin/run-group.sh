#!/usr/bin/env bash
# run-group.sh <repo> <branch>
# Per-group serialized runner. Reads the newest queued target, runs matching jobs
# from <repo>'s .gitolite/ci.yml, with concurrency throttling, wall-clock timeout,
# hardened rootless docker run, dependency caching, sops secret injection, and
# ephemeral-env create/update/teardown.
set -uo pipefail   # NOT -e: we handle errors explicitly so one job can't abort the loop

CICD_BASE="${CICD_BASE:-/home/cicd-runner/runner}"
# shellcheck disable=SC1090
. "$CICD_BASE/bin/lib.sh"; cicd_load_config || exit 1

repo="$1"; branch="$2"
group="$repo/$branch"
slug="$(slugify "$branch")"
Q="$RUNNER_BASE/queue/$group"
RUNS="$RUNNER_BASE/runs/$group"
ENVS="$RUNNER_BASE/envs/$repo/$slug"
CACHE="$RUNNER_BASE/cache/$repo"
BARE="$GIT_REPO_BASE/$repo.git"
export SOPS_AGE_KEY_FILE
[ -n "${DOCKER_HOST:-}" ] && export DOCKER_HOST

mkdir -p "$Q" "$RUNS" "$CACHE/npm" "$CACHE/nm"

# ---- per-group lock: if another run-group holds it, exit (it will coalesce) ----
exec 9>>"$Q/group.lock"
flock -n 9 || { log "$group already running; exit"; exit 0; }

# ---- global slot (held until this process exits) ----
acquire_slot

cleanup() { :; }   # slot/lock fds auto-release on exit
trap cleanup EXIT

# ---- helpers ----------------------------------------------------------------

git_changed() {  # git_changed <event> <newrev> <oldrev>  -> newline list of paths
  local ev="$1" new="$2" old="$3" ZERO=0000000000000000000000000000000000000000
  if [ "$ev" = "create" ] || [ "$old" = "$ZERO" ]; then
    git --git-dir="$BARE" ls-tree -r --name-only "$new" 2>/dev/null
  else
    git --git-dir="$BARE" diff --name-only "$old" "$new" 2>/dev/null
  fi
}

# Run one matched job inside a hardened, throwaway container.
execute_job() {  # execute_job <job> <event> <newrev> <pusher> <workdir> <manifest>
  local job="$1" event="$2" newrev="$3" pusher="$4" work="$5" manifest="$6"
  local image timeout mem pids network runcmd ts dir name envfile rc
  local retries rdelay notify try max
  image="$(yq_str "$manifest" ".jobs.\"$job\".image")";     image="${image:-$DEFAULT_IMAGE}"
  timeout="$(yq_str "$manifest" ".jobs.\"$job\".timeout")"; timeout="${timeout:-$DEFAULT_TIMEOUT}"
  mem="$(yq_str "$manifest" ".jobs.\"$job\".memory")";      mem="${mem:-$DEFAULT_MEMORY}"
  pids="$(yq_str "$manifest" ".jobs.\"$job\".pids")";       pids="${pids:-$DEFAULT_PIDS}"
  network="$(yq_str "$manifest" ".jobs.\"$job\".network")"; network="${network:-$DEFAULT_NETWORK}"
  runcmd="$(yq_str "$manifest" ".jobs.\"$job\".run")"
  [ -n "$runcmd" ] || { log "$group/$job: no run: command, skip"; return 0; }
  # per-job retry + notify (clamped to MAX_RETRIES so a typo can't pin the box)
  retries="$(yq_str "$manifest" ".jobs.\"$job\".retries")"; retries="${retries:-${DEFAULT_RETRIES:-0}}"
  retries="$(clamp_int "$retries" 0 "${MAX_RETRIES:-5}")"
  rdelay="$(yq_str "$manifest" ".jobs.\"$job\".\"retry-delay\"")"; rdelay="${rdelay:-${DEFAULT_RETRY_DELAY:-15}}"
  notify="$(yq_str "$manifest" ".jobs.\"$job\".notify")"; notify="${notify:-on-failure}"
  max=$(( 1 + retries ))

  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$RUNS/$ts-${newrev:0:8}-$job"; mkdir -p "$dir"
  name="cicd-$(printf '%s' "$group-$job" | tr -c 'a-zA-Z0-9_.-' '-')-$ts"
  printf '{"group":"%s","job":"%s","event":"%s","sha":"%s","branch":"%s","pusher":"%s","start":"%s"}\n' \
    "$group" "$job" "$event" "$newrev" "$branch" "$pusher" "$(_ts)" > "$dir/meta.json"
  echo running > "$dir/status"

  # --- secrets: decrypt repo's ci/secrets.enc.yaml to a tmpfs dotenv (if present) ---
  envfile=""
  if [ -f "$work/ci/secrets.enc.yaml" ]; then
    envfile="$(mktemp -p "${SHM_DIR:-/dev/shm}" cicd.env.XXXXXX)"
    if ! sops -d --output-type dotenv "$work/ci/secrets.enc.yaml" > "$envfile" 2>"$dir/secrets.err"; then
      echo "exit:secrets-decrypt-failed" > "$dir/status"
      rm -f "$envfile"
      notify_failure "$group/$job" secrets "$dir/output.log"
      log "$group/$job: secret decrypt failed (key loaded? run unlock-ci) — see $dir/secrets.err"
      return 1
    fi
    rm -f "$dir/secrets.err"
  fi

  # --- the exact invocation, recorded for hand-reproduction ---
  {
    echo "# event=$event sha=$newrev branch=$branch"
    echo "timeout --kill-after=30 $timeout docker run --rm --init --name $name \\"
    echo "  --cap-drop ALL --security-opt no-new-privileges --pids-limit $pids --memory $mem \\"
    echo "  --network $network --label cicd=1 --label cicd.group=$group \\"
    echo "  -e CI_EVENT=$event -e CI_REPO=$repo -e CI_BRANCH=$branch -e CI_BRANCH_SLUG=$slug \\"
    echo "  -e CI_SHA=$newrev -e CI_PUSHER=$pusher -e CI_CACHE_DIR=/cache -e npm_config_cache=/cache/npm \\"
    echo "  -v $CACHE:/cache -v $work:/work -w /work ${envfile:+--env-file <decrypted>} \\"
    echo "  $image sh -c '$runcmd'"
  } > "$dir/cmd"

  log "$group/$job: start image=$image timeout=$timeout net=$network retries=$retries"
  local status_word
  for try in $(seq 1 "$max"); do
    [ "$try" -gt 1 ] && { echo "=== retry $try/$max $(_ts) ===" >> "$dir/output.log"; }
    timeout --kill-after=30 "$timeout" \
      docker run --rm --init --name "${name}-$try" \
        --cap-drop ALL --security-opt no-new-privileges \
        --pids-limit "$pids" --memory "$mem" --network "$network" \
        --label cicd=1 --label "cicd.group=$group" \
        -e CI_EVENT="$event" -e CI_REPO="$repo" -e CI_BRANCH="$branch" \
        -e CI_BRANCH_SLUG="$slug" -e CI_SHA="$newrev" -e CI_PUSHER="$pusher" \
        -e CI_CACHE_DIR=/cache -e npm_config_cache=/cache/npm \
        -e CI_ENV_DIR=/envstate -v "$ENVS:/envstate" \
        -v "$CACHE:/cache" -v "$work:/work" -w /work \
        ${envfile:+--env-file "$envfile"} \
        "$image" sh -c "$runcmd" \
        >>"$dir/output.log" 2>&1
    rc=$?
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then docker rm -f "${name}-$try" >/dev/null 2>&1 || true; rc=124; fi
    [ "$rc" -eq 0 ] && break
    if [ "$try" -lt "$max" ]; then
      log "$group/$job: attempt $try failed (rc=$rc) — retry $((try+1))/$max in ${rdelay}s"
      sleep "$rdelay"
    fi
  done

  if [ "$rc" -eq 124 ]; then status_word=timeout; else status_word="exit:$rc"; fi
  echo "$status_word" > "$dir/status"
  ln -sfn "$dir" "$RUNS/latest"
  if [ "$rc" -ne 0 ]; then
    # pass the decrypted secrets so the notifier can use repo-level SMTP creds
    [ "$notify" != "off" ] && notify_failure "$group/$job" "$status_word after $max attempt(s)" "$dir/output.log" "$envfile"
    log "$group/$job: FAILED $status_word after $max attempt(s)"
  else
    log "$group/$job: done (attempt $try/$max)"
  fi
  [ -n "$envfile" ] && rm -f "$envfile"     # decrypted secrets gone after notify
  return "$rc"
}

# Persist the teardown plan so branch-deletion can tear down without the ref (DESIGN §14).
persist_env_for_teardown() {  # <work> <manifest>
  local work="$1" manifest="$2" tjob tscript timage
  # find the first job with an on.delete trigger
  for tjob in $(yq_keys "$manifest" ".jobs"); do
    local del; del="$(yq_str "$manifest" ".jobs.\"$tjob\".on.delete")"
    [ -n "$del" ] || continue
    tscript="$(yq_str "$manifest" ".jobs.\"$tjob\".run")"
    timage="$(yq_str "$manifest" ".jobs.\"$tjob\".image")"; timage="${timage:-$DEFAULT_IMAGE}"
    mkdir -p "$ENVS"
    # copy whatever the teardown run references (script path under ci/) if it exists
    [ -d "$work/ci" ] && cp -a "$work/ci/." "$ENVS/ci/" 2>/dev/null || true
    printf '%s\n' "$tscript" > "$ENVS/teardown.cmd"
    printf '%s\n' "$timage"  > "$ENVS/teardown.image"
    printf '{"repo":"%s","branch":"%s","slug":"%s","saved":"%s"}\n' \
      "$repo" "$branch" "$slug" "$(_ts)" > "$ENVS/meta.json"
    log "$group: persisted teardown plan for $slug (job=$tjob)"
    return 0
  done
}

find_delete_job() {  # find_delete_job <manifest> -> prints first job whose on.delete matches $branch
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

run_teardown() {  # run_teardown <oldrev> <pusher>
  local oldrev="$1" pusher="$2" ts dir name envfile rc
  local ZERO=0000000000000000000000000000000000000000
  local preserve="refs/cicd/preserve/$slug"
  local work="" manifest="" tjob="" image runcmd mountwork wd
  local retries="${DEFAULT_RETRIES:-0}" rdelay="${DEFAULT_RETRY_DELAY:-15}" notify="on-failure"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$RUNS/$ts-teardown"; mkdir -p "$dir"; echo running > "$dir/status"
  name="cicd-teardown-$(printf '%s' "$group" | tr -c 'a-zA-Z0-9_.-' '-')-$ts"

  # --- 1) get the FULL tree: preserve ref (primary) -> oldrev objects (gc window) ---
  if git --git-dir="$BARE" show-ref --verify --quiet "$preserve"; then
    work="$(mktemp -d)"; git --git-dir="$BARE" archive "$preserve" | tar -x -C "$work" 2>/dev/null || rm -rf "$work" work=""
  elif [ "$oldrev" != "$ZERO" ] && git --git-dir="$BARE" cat-file -e "$oldrev^{commit}" 2>/dev/null; then
    work="$(mktemp -d)"; git --git-dir="$BARE" archive "$oldrev" | tar -x -C "$work" 2>/dev/null || rm -rf "$work" work=""
  fi

  # --- 2) choose full-tree mode (have tree + manifest) or minimal fallback ---
  if [ -n "$work" ] && [ -f "$work/.gitolite/ci.yml" ]; then
    manifest="$work/.gitolite/ci.yml"
    if tjob="$(find_delete_job "$manifest")"; then
      image="$(yq_str "$manifest" ".jobs.\"$tjob\".image")"; image="${image:-$DEFAULT_IMAGE}"
      runcmd="$(yq_str "$manifest" ".jobs.\"$tjob\".run")"
      mountwork=(-v "$work:/work" -w /work); wd="$work"     # full project at /work, state at /envstate
      # per-job retry/notify from the delete job (clamped)
      retries="$(yq_str "$manifest" ".jobs.\"$tjob\".retries")"; retries="${retries:-${DEFAULT_RETRIES:-0}}"
      retries="$(clamp_int "$retries" 0 "${MAX_RETRIES:-5}")"
      rdelay="$(yq_str "$manifest" ".jobs.\"$tjob\".\"retry-delay\"")"; rdelay="${rdelay:-${DEFAULT_RETRY_DELAY:-15}}"
      notify="$(yq_str "$manifest" ".jobs.\"$tjob\".notify")"; notify="${notify:-on-failure}"
    fi
  fi
  if [ -z "${runcmd:-}" ] && [ -f "$ENVS/teardown.cmd" ]; then   # minimal fallback (reaper / no ref)
    image="$(cat "$ENVS/teardown.image" 2>/dev/null)"; image="${image:-$DEFAULT_IMAGE}"
    runcmd="$(cat "$ENVS/teardown.cmd")"
    mountwork=(-w /envstate)                                  # only persisted ci/ + state present
  fi
  if [ -z "${runcmd:-}" ]; then
    echo "exit:0" > "$dir/status"
    git --git-dir="$BARE" update-ref -d "$preserve" 2>/dev/null || true
    [ -n "$work" ] && rm -rf "$work"
    log "$group: nothing to tear down for $slug"; return 0
  fi

  # --- 3) secrets: prefer the tree's secrets file, else the persisted copy ---
  envfile=""
  local secsrc=""
  [ -n "$work" ] && [ -f "$work/ci/secrets.enc.yaml" ] && secsrc="$work/ci/secrets.enc.yaml"
  [ -z "$secsrc" ] && [ -f "$ENVS/ci/secrets.enc.yaml" ] && secsrc="$ENVS/ci/secrets.enc.yaml"
  if [ -n "$secsrc" ]; then
    envfile="$(mktemp -p "${SHM_DIR:-/dev/shm}" cicd.env.XXXXXX)"
    sops -d --output-type dotenv "$secsrc" > "$envfile" 2>/dev/null || { rm -f "$envfile"; envfile=""; }
  fi

  # Retry per the delete job's `retries:` (default DEFAULT_RETRIES) — guards against
  # intermittent network blips. After that it's the operator's problem: notify (unless
  # notify: off) + KEEP ref/state, NO further auto-retry (reap-envs skips teardown-failed).
  mkdir -p "$ENVS"
  local max=$(( 1 + retries )) try rc
  for try in $(seq 1 "$max"); do
    log "$group: teardown $slug (mode=$([ -n "$work" ] && echo full-tree || echo minimal) attempt=$try/$max)"
    { echo "=== teardown attempt $try/$max $(_ts) ==="; } >> "$dir/output.log"
    date -u +%s > "$ENVS/last_attempt"
    timeout --kill-after=30 "${DEFAULT_TIMEOUT}" \
      docker run --rm --init --name "${name}-$try" \
        --cap-drop ALL --security-opt no-new-privileges \
        --pids-limit "$DEFAULT_PIDS" --memory "$DEFAULT_MEMORY" --network "$DEFAULT_NETWORK" \
        --label cicd=1 --label "cicd.group=$group" \
        -e CI_EVENT=delete -e CI_REPO="$repo" -e CI_BRANCH="$branch" \
        -e CI_BRANCH_SLUG="$slug" -e CI_PUSHER="$pusher" \
        -e CI_ENV_DIR=/envstate -v "$ENVS:/envstate" \
        "${mountwork[@]}" \
        ${envfile:+--env-file "$envfile"} \
        "$image" sh -c "$runcmd" \
        >>"$dir/output.log" 2>&1
    rc=$?
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then docker rm -f "${name}-$try" >/dev/null 2>&1 || true; rc=1; fi
    [ "$rc" -eq 0 ] && break
    if [ "$try" -lt "$max" ]; then
      log "$group: teardown attempt $try failed (exit $rc) — retry $((try+1))/$max in ${rdelay}s"
      sleep "$rdelay"
    fi
  done
  echo "exit:$rc" > "$dir/status"; ln -sfn "$dir" "$RUNS/latest"

  if [ "$rc" -eq 0 ]; then
    git --git-dir="$BARE" update-ref -d "$preserve" 2>/dev/null || true   # release objects -> gc may reclaim
    rm -rf "$ENVS"                                                        # env destroyed; clear state + cache
    log "$group: teardown done"
  else
    # exhausted retries -> hand to the operator. KEEP preserve ref + env state.
    printf 'exit:%s after %s attempt(s) @ %s\nlog: %s\n' "$rc" "$max" "$(_ts)" "$dir/output.log" \
      > "$ENVS/teardown-failed"
    [ "$notify" != "off" ] && notify_failure "$group teardown" "FAILED after $max attempt(s) — NEEDS OPERATOR (ci-teardown retry|abandon)" "$dir/output.log" "$envfile"
    log "$group: teardown FAILED after $max attempt(s) — ref+state KEPT, no auto-retry"
  fi
  [ -n "$envfile" ] && rm -f "$envfile"
  [ -n "$work" ] && rm -rf "$work"
  return "$rc"
}

# Process one create/push target: checkout, match jobs, run them.
process_build() {  # <event> <newrev> <oldrev> <pusher>
  local event="$1" newrev="$2" oldrev="$3" pusher="$4"
  local work manifest changed any=1
  work="$(mktemp -d)"
  if ! git --git-dir="$BARE" archive "$newrev" | tar -x -C "$work" 2>/dev/null; then
    log "$group: checkout $newrev failed"; rm -rf "$work"; return 1
  fi
  manifest="$work/.gitolite/ci.yml"
  [ -f "$manifest" ] || { log "$group: no .gitolite/ci.yml at $newrev"; rm -rf "$work"; return 0; }
  changed="$(git_changed "$event" "$newrev" "$oldrev")"

  local job inc ign pinc pign
  for job in $(yq_keys "$manifest" ".jobs"); do
    # does this job declare the current event?
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

  # persist teardown plan (so a future branch-delete can tear this env down)
  persist_env_for_teardown "$work" "$manifest"
  [ "$any" -ne 0 ] && log "$group: no jobs matched $event on $branch"
  rm -rf "$work"
  return 0
}

# ---- coalescing main loop ---------------------------------------------------
last=""
while :; do
  [ -f "$Q/target" ] || break
  target="$(cat "$Q/target")"
  [ "$target" = "$last" ] && break          # nothing new -> done
  read -r event newrev oldrev pusher <<< "$target"
  pusher="${pusher:-unknown}"

  case "$event" in
    delete)
      run_teardown "$oldrev" "$pusher"
      ;;
    create|push)
      # delete-supersedes: if a delete landed while we were about to build, skip to it
      if [ "${DELETE_SUPERSEDES:-1}" = "1" ]; then
        nxt="$(cat "$Q/target")"; read -r nev _ _ _ <<< "$nxt"
        [ "$nev" = "delete" ] && { last=""; continue; }
      fi
      process_build "$event" "$newrev" "$oldrev" "$pusher"
      ;;
    *) log "$group: unknown event '$event'";;
  esac

  last="$target"
  # coalesce: loop re-reads target; if a newer push arrived during the run, run newest,
  # skipping intermediates. Stable target -> loop exits at the top.
done

printf '%s\n' "$last" > "$Q/last"   # crash-recovery marker (ci-recover compares to target)
log "$group: idle"
