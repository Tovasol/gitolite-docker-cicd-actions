#!/usr/bin/env bash
# cicd-runner shared library. Sourced by all scripts. Not executable on its own.
# Provides: config loading, logging, glob matching (GitHub-ish), trust check,
# slug, notify, slot semaphore helpers.

# --- locate + load config -----------------------------------------------------
cicd_load_config() {
  # Search order: explicit CICD_CONF -> $CICD_BASE/etc (user-local, ABSOLUTE so it
  # survives `sudo -u cicd-runner` where $HOME may still be git's) -> /etc (optional
  # system-wide). No sudo / no /etc copy needed; the git hook is self-contained and
  # never reads this.
  local c
  for c in "${CICD_CONF:-}" "${CICD_BASE:-$HOME/runner}/etc/runner.conf" \
           /etc/cicd-runner/runner.conf; do
    [ -n "$c" ] && [ -f "$c" ] && { # shellcheck disable=SC1090
      . "$c"; CICD_CONF="$c"
      # sudo resets PATH to secure_path, dropping ~/.local/bin where sops/yq live.
      # Prepend the configured LOCAL_BIN so the runner finds them under sudo.
      if [ -n "${LOCAL_BIN:-}" ]; then
        case ":$PATH:" in *":$LOCAL_BIN:"*) ;; *) PATH="$LOCAL_BIN:$PATH"; export PATH ;; esac
      fi
      return 0; }
  done
  echo "cicd-runner: no runner.conf found (looked in \$CICD_BASE/etc and /etc/cicd-runner)" >&2
  return 1
}

# --- logging ------------------------------------------------------------------
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { printf '%s %s\n' "$(_ts)" "$*"; }
die()  { printf '%s ERROR: %s\n' "$(_ts)" "$*" >&2; exit 1; }

# --- audit log (append-only, hash-chained / tamper-evident) -------------------
_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1; fi
}
# Append a security-audit entry. Each line carries hash=sha256(prev_hash + payload), so any
# edit/delete/reorder of a past line breaks the chain (cicd_audit_verify detects it). Appends
# are serialized with flock so concurrent writers (ingest/run-group/unlock) can't fork the
# chain. Best-effort — never aborts the caller. Line: <ts>\t<event>\t<fields>\tprev=H\thash=H
cicd_audit() {  # <event> [k=v ...]
  [ "${AUDIT_ENABLED:-1}" = 1 ] || return 0
  local logf="${AUDIT_LOG:-${RUNNER_BASE:-$HOME/runner}/audit.log}"
  local ev="${1:-?}"; shift 2>/dev/null || true
  local ts fields payload
  ts="$(_ts)"
  # L4: strip ALL control bytes from fields (not just NL/TAB) — CR/VT/FF/ESC could overwrite or
  # color the line at the `ci-audit tail` render layer, spoofing which job/pusher an event names.
  fields="$(printf '%s' "$*" | tr -d '[:cntrl:]')"
  payload="$(printf '%s\t%s\t%s' "$ts" "$ev" "$fields")"
  # L1: serialize the read-prev + append so concurrent writers can't fork the chain. flock on
  # Linux; a portable mkdir-mutex where flock is absent (macOS/busybox) — the bare fd redirect
  # alone does NOT serialize, which silently broke the chain under concurrent pushes.
  if command -v flock >/dev/null 2>&1; then
    { flock 9 2>/dev/null || true; _cicd_audit_append "$logf" "$payload"; } 9>>"${logf}.lock" 2>/dev/null || true
  else
    # No flock: portable mkdir-mutex. A writer killed mid-audit leaks the lockdir; the old code
    # then spun ~6s and failed OPEN (unlocked append -> concurrent writers FORK the hash chain,
    # destroying tamper-evidence). Now: stamp the owner pid, and a later writer RECLAIMS a lock
    # whose owner is dead OR whose dir is older than AUDIT_LOCK_STALE_SECS. If serialization still
    # can't be had, append a 'serialization=lost' sentinel so a resulting fork is attributable to
    # a lock loss, not silent tampering. (No EXIT trap — it would clobber the caller's trap.)
    local _ld="${logf}.lock.d" _n=0 _owner
    while ! mkdir "$_ld" 2>/dev/null; do
      _owner="$(cat "$_ld/pid" 2>/dev/null || true)"
      if { [ -n "$_owner" ] && ! kill -0 "$_owner" 2>/dev/null; } || _audit_lock_stale "$_ld"; then
        rm -rf "$_ld" 2>/dev/null || true; continue          # reclaim a leaked/stale lock
      fi
      _n=$((_n + 1))
      if [ "$_n" -gt "${AUDIT_LOCK_MAX_SPINS:-300}" ]; then
        _cicd_audit_append "$logf" "$(printf '%s\tserialization=lost' "$payload")"; return 0
      fi
      sleep 0.02 2>/dev/null || sleep 1
    done
    printf '%s' "$$" > "$_ld/pid" 2>/dev/null || true
    _cicd_audit_append "$logf" "$payload"
    rm -rf "$_ld" 2>/dev/null || true
  fi
}
# A mkdir-mutex lockdir is stale if older than AUDIT_LOCK_STALE_SECS (a held lock is refreshed by
# being short-lived; anything older leaked). BSD `stat -f %m` / GNU `stat -c %Y`.
_audit_lock_stale() {  # <lockdir>
  local d="$1" now mtime
  now="$(date +%s 2>/dev/null)" || return 1
  mtime="$(stat -f %m "$d" 2>/dev/null || stat -c %Y "$d" 2>/dev/null)" || return 1
  [ "$(( now - mtime ))" -gt "${AUDIT_LOCK_STALE_SECS:-30}" ]
}
# Append one chained entry. Caller MUST hold the audit lock (serializes read-prev + append).
_cicd_audit_append() {  # <logf> <payload>
  local prev=""
  [ -f "$1" ] && prev="$(tail -n1 "$1" 2>/dev/null | sed -n 's/.*[[:space:]]hash=\([0-9a-f]*\).*/\1/p')"
  prev="${prev:-GENESIS}"
  printf '%s\tprev=%s\thash=%s\n' "$2" "$prev" "$(printf '%s%s' "$prev" "$2" | _sha256_stdin)" >> "$1"
}
# Verify the chain. Echoes "audit: OK (N entries)" + returns 0, or reports the first broken
# entry + returns 1. Extracts prev/hash from the LAST \tprev=/\thash= so a field value that
# happens to contain "prev="/"hash=" can't fool it.
cicd_audit_verify() {  # [logfile]
  local logf="${1:-${AUDIT_LOG:-${RUNNER_BASE:-$HOME/runner}/audit.log}}"
  [ -f "$logf" ] || { echo "audit: no log at $logf"; return 0; }
  local prev="GENESIS" n=0 line rest payload rec_prev rec_hash calc
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    rec_hash="${line##*$'\t'hash=}"
    rest="${line%$'\t'hash=*}"
    rec_prev="${rest##*$'\t'prev=}"
    payload="${rest%$'\t'prev=*}"
    calc="$(printf '%s%s' "$prev" "$payload" | _sha256_stdin)"
    if [ "$rec_prev" != "$prev" ] || [ "$rec_hash" != "$calc" ]; then
      echo "audit: CHAIN BROKEN at entry $n: $payload" >&2; return 1
    fi
    prev="$rec_hash"
  done < "$logf"
  echo "audit: OK ($n entries)"; return 0
}

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
  local value="$1" list="$2" p parts
  list="${list//,/ }"
  # split on whitespace WITHOUT pathname expansion — `for p in $list` would glob-expand
  # the patterns themselves against the runner's CWD (e.g. "site/**" -> "site/scaffold"),
  # silently breaking filters. `read -ra` splits on IFS and never globs.
  read -ra parts <<< "$list"
  for p in "${parts[@]}"; do glob_match "$value" "$p" && return 0; done
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
# Deliver ONE notification host-side. level: info|success|error. The project's
# decrypted secrets (secenv) let the notifier use repo-level SMTP creds; else host default.
cicd_deliver() {  # cicd_deliver <level> <label> <message> <logpath> [secenv]
  [ -n "${NOTIFY_CMD:-}" ] || return 0
  local out
  # Capture the notifier's audit line (recipients + OK/FAIL) into the run log instead of
  # discarding it, so `ci-log` shows WHO was notified. Still never blocks/fails the runner.
  # shellcheck disable=SC2086
  out="$(CICD_NOTIFY_ENV="${5:-${CICD_NOTIFY_ENV:-/etc/cicd-runner/notify.env}}" \
    $NOTIFY_CMD "$2" "$1: $3" "$4" </dev/null 2>&1 || true)"
  [ -n "$out" ] && printf '%s\n' "$out" >> "$4"
  return 0
}

# Flush a job's outbox (script-emitted notify_* lines) after the container exits,
# then apply the failure backstop (alert even if the script emitted nothing — e.g.
# OOM/SIGKILL). Notifications are also copied into the run's output.log.
cicd_flush_outbox() {  # cicd_flush_outbox <outboxfile> <rc> <logdir> <label> [secenv] [maskfile]
  local box="$1" rc="$2" dir="$3" label="$4" secenv="${5:-}" maskfile="${6:-}" had_terminal=0 line level msg
  # The outbox lives in the RW /cicd/out mount the job container controls. A job can plant
  # `notify -> /run/ci-keys/age-keys.txt` (the SOPS age MASTER key) so this host-side read
  # follows the link and echoes the key into output.log (readable via `ci-job log`). lstat-reject
  # any symlink before reading — the per-job redactor wouldn't mask a cross-repo key anyway (H2).
  if [ -L "$box" ]; then
    echo "[notify] outbox was a symlink — refused to read (H2 exfil guard)" >> "$dir/output.log"
    rm -f "$box"
  elif [ -f "$box" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      level="$(printf '%s' "$line" | cut -f1)"; msg="$(printf '%s' "$line" | cut -f2-)"
      # a script-authored notify message bypasses the container-stream redactor, so mask it
      # here too before it hits output.log / the email (closes the last redaction gap).
      [ -s "$maskfile" ] && msg="$(printf '%s' "$msg" | sed -f "$maskfile" 2>/dev/null)"
      echo "[notify:$level] $msg" >> "$dir/output.log"
      case "$level" in success|error) had_terminal=1 ;; esac
      cicd_deliver "$level" "$label" "$msg" "$dir/output.log" "$secenv"
    done < "$box"
  fi
  if [ "$rc" -ne 0 ] && [ "$had_terminal" -eq 0 ] && [ "${NOTIFY_BACKSTOP:-1}" = "1" ]; then
    cicd_deliver error "$label" "job failed (rc=$rc) with no script notification" "$dir/output.log" "$secenv"
  fi
}

# Runner-originated failure alert (secrets-decrypt, teardown operator handoff).
notify_failure() {  # notify_failure <label> <status> <logpath> [secenv]
  log "FAILURE $1 $2 log=$3"
  cicd_deliver error "$1" "$2" "$3" "${4:-}"
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
