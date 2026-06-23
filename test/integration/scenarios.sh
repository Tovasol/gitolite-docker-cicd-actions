#!/usr/bin/env bash
# Integration scenarios — the REAL control plane (gitolite authz -> ci-job -> archive-push
# -> cicd-ingest -> run-group -> queue -> meta -> ci-status), with only the container/
# isolation leaf mocked. Run as the image ENTRYPOINT. Exit 0 = all passed.
set -uo pipefail
P=0; F=0
ok(){ printf '  \033[32m[PASS]\033[0m %s\n' "$*"; P=$((P+1)); }
no(){ printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; F=$((F+1)); }
LC="$(sudo -u git -H gitolite query-rc LOCAL_CODE 2>/dev/null)"
CIJOB="$LC/commands/ci-job"
runs=/home/cicd-runner/runner/runs
asuser(){ u="$1"; shift; sudo -u git -H env GL_USER="$u" "$CIJOB" "$@"; }
asrun(){ sudo -u cicd-runner -H bash -lc "$*"; }
wait_status(){ # <repo> -> terminal status or (timeout)
  local r="$1" i m s
  for i in $(seq 1 40); do
    m="$(asrun "ls -1t $runs/$r/*/meta.json 2>/dev/null | head -1")"
    if [ -n "$m" ]; then
      s="$(asrun "grep -o '\"status\":\"[^\"]*\"' '$m' | head -1")"
      case "$s" in *exit:*|*timeout*) echo "$s"; return 0 ;; esac
    fi; sleep 0.5
  done; echo "(timeout)"; return 1
}

printf '\033[1m== A) package management: stack tools pinned + sha-verified + installed ==\033[0m\n'
for t in yq duckdb sops age; do
  asrun "command -v $t >/dev/null" && ok "tool present: $t" || no "tool MISSING: $t"
done

printf '\033[1m== B) E2E: ci-job run (alice, WRITE on app) -> real archive-push -> run-group -> meta ==\033[0m\n'
asuser alice run app master --job build >/dev/null 2>&1 || true
st="$(wait_status app)"; case "$st" in *exit:0*) ok "green run recorded ($st)" ;; *) no "run status: $st" ;; esac

printf '\033[1m== C) ci-status shows the run (real DuckDB analytics over real meta) ==\033[0m\n'
asrun "ci-status app 2>/dev/null" | grep -q 'app/build' && ok "ci-status lists app/build" || no "ci-status missing app/build"

printf '\033[1m== D) access scoping: bob (R lib, NO app) must not see app ==\033[0m\n'
sb="$(asuser bob status 2>&1)"; echo "$sb" | grep -q 'app/' && no "bob saw app (should be hidden)" || ok "bob status excludes app"

printf '\033[1m== E) denial: alice has only R on lib -> run must be refused ==\033[0m\n'
if asuser alice run lib master >/dev/null 2>&1; then no "alice ran lib (should be denied)"; else ok "alice denied run on lib (no WRITE)"; fi

printf '\033[1m== F) failing job: mock docker run_rc=1 -> meta exit:1 ==\033[0m\n'
asrun "rm -rf $runs/app/* 2>/dev/null" || true
echo 1 > /tmp/mockdocker/run_rc
asuser alice run app master --job build >/dev/null 2>&1 || true
st="$(wait_status app)"; echo 0 > /tmp/mockdocker/run_rc
case "$st" in *exit:1*) ok "failing job recorded exit:1 ($st)" ;; *) no "expected exit:1, got $st" ;; esac

printf '\033[1m== G) deferred-recovery: docker DOWN -> run defers (no meta) -> docker UP + ci-recover -> runs ==\033[0m\n'
asrun "rm -rf $runs/app/* 2>/dev/null" || true
echo 1 > /tmp/mockdocker/info_rc      # docker "down"
asuser alice run app master --job build >/dev/null 2>&1 || true
sleep 1
deferred=$(asrun "ls $runs/app/*/meta.json 2>/dev/null | wc -l")
echo 0 > /tmp/mockdocker/info_rc      # docker "up"
asrun "ci-recover >/dev/null 2>&1" || true
st="$(wait_status app)"
if [ "$deferred" -eq 0 ] && { case "$st" in *exit:0*) true ;; *) false ;; esac; }; then
  ok "deferred while docker down, then ran after recover ($st)"
else no "deferred-recovery: deferred-metas=$deferred final=$st"; fi

printf '\n\033[1mintegration: %d passed, %d failed\033[0m\n' "$P" "$F"
[ "$F" -eq 0 ]
