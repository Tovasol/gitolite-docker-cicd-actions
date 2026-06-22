# cicd.sh — reusable helpers for ci/*.sh scripts. POSIX sh (works in busybox ash).
# The runner mounts this read-only at /cicd/lib.sh. Source it at the top of your script:
#     . /cicd/lib.sh
#
# Available env (injected by the runner): CI_EVENT CI_REPO CI_BRANCH CI_BRANCH_SLUG
#   CI_SHA CI_PUSHER CI_CACHE_DIR CI_ENV_DIR  (+ your decrypted secrets as env vars).
#
# notify*() do NOT send mail — they append to a mounted outbox; the runner delivers
# host-side (so it works in any image, needs no curl/creds in the container, and is
# flushed even if the job is later OOM/timeout-killed).

_CICD_OUTBOX="${CI_OUTBOX:-/cicd/out/notify}"

_cicd_emit() {  # _cicd_emit <level> <message...>
  _lvl="$1"; shift
  printf '%s\t%s\n' "$_lvl" "$*" >> "$_CICD_OUTBOX" 2>/dev/null || true
}
notify()         { _cicd_emit info    "$*"; }   # informational
notify_success() { _cicd_emit success "$*"; }   # terminal OK   -> "[CI OK]"
notify_error()   { _cicd_emit error   "$*"; }   # terminal fail -> "[CI FAIL]"

# retry [-n tries] [-d delay] -- <cmd...>   (defaults: 3 tries, 10s apart)
# Retries the SINGLE command (granular) — far better than retrying the whole job.
retry() {
  _n=3; _d=10
  while [ $# -gt 0 ]; do
    case "$1" in
      -n) _n="$2"; shift 2 ;;
      -d) _d="$2"; shift 2 ;;
      --) shift; break ;;
      *)  break ;;
    esac
  done
  _i=1
  while :; do
    "$@" && return 0
    _rc=$?
    if [ "$_i" -ge "$_n" ]; then echo "retry: gave up after $_n (rc=$_rc): $*" >&2; return "$_rc"; fi
    echo "retry: attempt $_i/$_n failed (rc=$_rc); sleep ${_d}s: $*" >&2
    sleep "$_d"; _i=$((_i + 1))
  done
}

# wait_all <pid>...  -> 0 if all succeeded, 1 if any failed. The fan-in primitive.
wait_all() {
  _rc=0
  for _p in "$@"; do wait "$_p" || _rc=1; done
  return "$_rc"
}

# step <name...> — print a stage marker (shows in the run's output.log)
step() { printf '\n=== %s ===\n' "$*"; }

# die <message...> — notify_error + abort the job
die() { notify_error "$*"; echo "FATAL: $*" >&2; exit 1; }
