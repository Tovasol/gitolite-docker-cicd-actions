#!/usr/bin/env bash
# cicd-runner shared library. Sourced by all scripts. Not executable on its own.
# Provides: config loading, logging, glob matching (GitHub-ish), trust check,
# slug, notify, slot semaphore helpers.

# --- locate + load config -----------------------------------------------------
cicd_load_config() {
  local c
  for c in "${CICD_CONF:-}" /etc/cicd-runner/runner.conf \
           "${RUNNER_BASE:-$HOME/runner}/etc/runner.conf"; do
    [ -n "$c" ] && [ -f "$c" ] && { # shellcheck disable=SC1090
      . "$c"; CICD_CONF="$c"; return 0; }
  done
  echo "cicd-runner: no runner.conf found (set CICD_CONF or create /etc/cicd-runner/runner.conf)" >&2
  return 1
}

# --- logging ------------------------------------------------------------------
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { printf '%s %s\n' "$(_ts)" "$*"; }
die()  { printf '%s ERROR: %s\n' "$(_ts)" "$*" >&2; exit 1; }

# --- GitHub-ish glob matching -------------------------------------------------
# `*` matches within a path segment (not `/`); `**` matches across; `?` one char.
glob_to_regex() {
  local glob="$1" out="" c i n="${#1}"
  for (( i=0; i<n; i++ )); do
    c="${glob:i:1}"
    case "$c" in
      '*')
        if [ "${glob:i+1:1}" = '*' ]; then
          # '**/' = zero-or-more path segments (matches with OR without a prefix);
          # trailing '**' = anything (incl '/').
          if [ "${glob:i+2:1}" = '/' ]; then out+='(.*/)?'; ((i+=2)); else out+='.*'; ((i++)); fi
        else out+='[^/]*'; fi ;;
      '?') out+='[^/]' ;;
      '.'|'+'|'('|')'|'['|']'|'{'|'}'|'^'|'$'|'|'|'\\') out+="\\$c" ;;
      *) out+="$c" ;;
    esac
  done
  printf '^%s$' "$out"
}
glob_match() { local re; re="$(glob_to_regex "$2")"; [[ "$1" =~ $re ]]; }

# Match a value against a space/comma-separated list of globs. Empty list => no match.
matches_any() {
  local value="$1" list="$2" p
  list="${list//,/ }"
  for p in $list; do glob_match "$value" "$p" && return 0; done
  return 1
}

# branch include/ignore semantics: empty include => match-all; ignore wins.
branch_matches() {
  local branch="$1" include="$2" ignore="$3"
  if [ -n "$ignore" ] && matches_any "$branch" "$ignore"; then return 1; fi
  if [ -z "$include" ]; then return 0; fi
  matches_any "$branch" "$include"
}

# any changed path matches include (and not ignore). Empty include => match-all.
paths_match() {
  local changed="$1" include="$2" ignore="$3" f hit=1
  [ -z "$include" ] && [ -z "$ignore" ] && return 0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ -n "$ignore" ] && matches_any "$f" "$ignore"; then continue; fi
    if [ -z "$include" ] || matches_any "$f" "$include"; then hit=0; break; fi
  done <<< "$changed"
  return $hit
}

is_trusted_branch() { matches_any "$1" "${TRUSTED_BRANCHES:-}"; }

# clamp_int <value> <lo> <hi> -> integer in [lo,hi]; non-numeric -> lo
clamp_int() {
  local v="$1" lo="$2" hi="$3"
  case "$v" in (*[!0-9]*|'') v="$lo";; esac
  [ "$v" -lt "$lo" ] && v="$lo"
  [ "$v" -gt "$hi" ] && v="$hi"
  printf '%s' "$v"
}

# --- slug: DNS-safe, deterministic, collision-resistant -----------------------
slugify() {
  local raw="$1" base h
  base="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40)"
  h="$(printf '%s' "$raw" | sha1sum | cut -c1-6)"
  printf '%s-%s' "${base:-x}" "$h"
}

# --- yaml field helpers (require yq v4 / mikefarah) ---------------------------
yq_str()  { yq -r "$2 // \"\"" "$1" 2>/dev/null; }
yq_list() { yq -r "$2 // [] | join(\" \")" "$1" 2>/dev/null; }   # array -> space list
yq_keys() { yq -r "$2 // {} | keys | .[]" "$1" 2>/dev/null; }

# --- notify -------------------------------------------------------------------
notify_failure() {
  local group="$1" status="$2" logpath="$3" secenv="${4:-}"
  log "FAILURE group=$group status=$status log=$logpath"
  [ -n "${NOTIFY_CMD:-}" ] || return 0
  # Pass the project's decrypted secrets (dotenv) so the notifier can read repo-level
  # SMTP creds (per-project notify). Falls back to the host default inside the notifier.
  # shellcheck disable=SC2086
  CICD_NOTIFY_ENV="${secenv:-${CICD_NOTIFY_ENV:-/etc/cicd-runner/notify.env}}" \
    $NOTIFY_CMD "$group" "$status" "$logpath" </dev/null >/dev/null 2>&1 || true
}

# --- global concurrency semaphore (flock on slot files) -----------------------
# Acquires a slot, holds fd $1 open for the caller's lifetime. Caller keeps the fd.
acquire_slot() {  # acquire_slot <fd-var-not-used> ; returns 0 and exports CICD_SLOT_FD
  local i max="${MAX_JOBS:-4}"
  mkdir -p "$RUNNER_BASE/slots"
  while :; do
    for (( i=1; i<=max; i++ )); do
      : > "$RUNNER_BASE/slots/$i" 2>/dev/null || true
      exec {CICD_SLOT_FD}>>"$RUNNER_BASE/slots/$i"
      if flock -n "$CICD_SLOT_FD"; then return 0; fi
      exec {CICD_SLOT_FD}>&-   # close, try next
    done
    sleep "${SLOT_WAIT_SECS:-2}"
  done
}
