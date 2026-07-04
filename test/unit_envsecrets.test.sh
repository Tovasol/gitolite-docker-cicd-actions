#!/usr/bin/env bash
# Unit tests for per-environment secret scoping in run-group.sh:
#   * resolve_env: default = sanitized branch; host-side map aliases branch -> env;
#     env comes from the TRUSTED branch, never the pushed manifest.
#   * has_env_secrets / has_any_secrets: detect per-env vs legacy layout.
#   * select_secrets_file: env file wins; REFUSE (rc2) when per-env exist but none for
#     this env; legacy single-file only when no per-env files exist; nothing = empty.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/harness.sh"
export CICD_BASE="$HERE/.."
# shellcheck source=/dev/null
. "$HERE/../bin/run-group.sh"     # _CICD_MAIN=0 -> functions only

W="$(mktemp -d)"
RUNNER_BASE="$W/rb"; mkdir -p "$RUNNER_BASE/etc"
unset CICD_ENV_MAP

suite "resolve_env — default = sanitized branch (no map)"
assert_eq "dev branch -> dev"        "$(resolve_env tovasol/site dev)"        "dev"
assert_eq "prod branch -> prod"      "$(resolve_env tovasol/site prod)"       "prod"
assert_eq "uppercase lowered"        "$(resolve_env tovasol/site QA)"         "qa"
assert_eq "slash/underscore -> dash" "$(resolve_env tovasol/site feat/x_y)"   "feat-x-y"

suite "resolve_env — host-side map aliases (trusted, not from manifest)"
MAP="$W/env.map"; export CICD_ENV_MAP="$MAP"
cat > "$MAP" <<'EOF'
# repo-glob   branch-glob   env
tovasol/*      main          prod
tovasol/*      release/*     prod
tovasol/*      staging       qa
EOF
assert_eq "main -> prod (aliased)"     "$(resolve_env tovasol/site main)"        "prod"
assert_eq "release/* -> prod"          "$(resolve_env tovasol/site release/1.2)" "prod"
assert_eq "staging -> qa"              "$(resolve_env tovasol/site staging)"     "qa"
assert_eq "unmapped falls to branch"   "$(resolve_env tovasol/site dev)"         "dev"
assert_eq "repo not matched -> branch" "$(resolve_env other/site main)"         "main"
unset CICD_ENV_MAP

suite "has_env_secrets / has_any_secrets"
E="$W/e"; mkdir -p "$E/ci"; : > "$E/ci/secrets.dev.enc.yaml"
L="$W/l"; mkdir -p "$L/ci"; : > "$L/ci/secrets.enc.yaml"
N="$W/n"; mkdir -p "$N/ci"
assert_ok   "per-env dir has env secrets"    has_env_secrets "$E"
assert_fail "legacy-only has NO env secrets" has_env_secrets "$L"
assert_ok   "legacy dir has any secrets"     has_any_secrets "$L"
assert_ok   "per-env dir has any secrets"    has_any_secrets "$E"
assert_fail "empty dir has no secrets"       has_any_secrets "$N"

suite "select_secrets_file — env wins, refuse cross-tier, legacy fallback"
P="$W/p"; mkdir -p "$P/ci"
: > "$P/ci/secrets.dev.enc.yaml"; : > "$P/ci/secrets.prod.enc.yaml"
out="$(select_secrets_file "$P" dev)"; rc=$?
assert_eq "dev env -> dev file"  "$out" "$P/ci/secrets.dev.enc.yaml"
assert_eq "dev env -> rc 0"      "$rc"  "0"
out="$(select_secrets_file "$P" prod)"; assert_eq "prod env -> prod file" "$out" "$P/ci/secrets.prod.enc.yaml"
# per-env files exist but NONE for 'qa' -> refuse (rc2), no legacy fallback
out="$(select_secrets_file "$P" qa)"; rc=$?
assert_eq "missing tier -> refuse rc2" "$rc" "2"
assert_eq "missing tier -> no path"    "$out" ""
# legacy-only tree: fall back to single file regardless of env name
out="$(select_secrets_file "$L" prod)"; rc=$?
assert_eq "legacy fallback path"  "$out" "$L/ci/secrets.enc.yaml"
assert_eq "legacy fallback rc 0"  "$rc"  "0"
# no secrets at all -> empty, rc0
out="$(select_secrets_file "$N" dev)"; rc=$?
assert_eq "no secrets -> empty"   "$out" ""
assert_eq "no secrets -> rc 0"    "$rc"  "0"

suite "secret_in_tree — refuse planted symlinks (host-side decrypt guard, F1-class)"
S="$W/s"; mkdir -p "$S/ci"; : > "$S/ci/secrets.dev.enc.yaml"; OUT="$W/outside.enc.yaml"; : > "$OUT"
assert_ok   "real file in ci/ ok"            secret_in_tree "$S" "$S/ci/secrets.dev.enc.yaml"
ln -sf "$OUT" "$S/ci/secrets.qa.enc.yaml"                       # leaf symlink -> outside tree
assert_fail "leaf symlink refused"           secret_in_tree "$S" "$S/ci/secrets.qa.enc.yaml"
ln -sf /etc/hostname "$S/ci/secrets.prod.enc.yaml"             # symlink -> arbitrary host file
assert_fail "symlink to host file refused"   secret_in_tree "$S" "$S/ci/secrets.prod.enc.yaml"
# ci/ itself is a symlink to a host dir -> whole dir escapes
CS="$W/cs"; mkdir -p "$CS"; ln -s /etc "$CS/ci"
assert_fail "symlinked ci/ dir refused"      secret_in_tree "$CS" "$CS/ci/hostname"

suite "select_secrets_file — planted symlink cannot be decrypted or fall back"
# secrets.dev.enc.yaml is a symlink to the real prod ciphertext (the copy/rename F1 vector, symlink form).
# dev env must NOT resolve to it; per-env prod file is present -> REFUSE rc2, no path, no legacy leak.
K="$W/k"; mkdir -p "$K/ci"; : > "$K/ci/secrets.prod.enc.yaml"
ln -sf "$K/ci/secrets.prod.enc.yaml" "$K/ci/secrets.dev.enc.yaml"
out="$(select_secrets_file "$K" dev)"; rc=$?
assert_eq "symlinked dev tier -> refuse rc2" "$rc"  "2"
assert_eq "symlinked dev tier -> no path"    "$out" ""
# legacy secrets.enc.yaml as a symlink -> not decrypted, treated as no secrets (fails safe)
M="$W/m"; mkdir -p "$M/ci"; ln -sf /etc/hostname "$M/ci/secrets.enc.yaml"
out="$(select_secrets_file "$M" dev)"; rc=$?
assert_eq "symlinked legacy -> empty"        "$out" ""
assert_eq "symlinked legacy -> rc 0"         "$rc"  "0"

suite "secrets_keyfile — per-tier key routing (only the resolved tier's key)"
AGE_KEY_DIR="/run/ci-keys"; SOPS_AGE_KEY_FILE="/run/ci-keys/age-keys.txt"
assert_eq "dev per-env -> dev.age"   "$(secrets_keyfile dev  /w/ci/secrets.dev.enc.yaml)"  "/run/ci-keys/dev.age"
assert_eq "qa per-env -> qa.age"     "$(secrets_keyfile qa   /w/ci/secrets.qa.enc.yaml)"   "/run/ci-keys/qa.age"
assert_eq "prod per-env -> prod.age" "$(secrets_keyfile prod /w/ci/secrets.prod.enc.yaml)" "/run/ci-keys/prod.age"
assert_eq "legacy file -> legacy key" "$(secrets_keyfile dev /w/ci/secrets.enc.yaml)"      "/run/ci-keys/age-keys.txt"
# trailing-slash dir normalized; unset AGE_KEY_DIR -> empty (treated as not-loaded -> DEFER)
AGE_KEY_DIR="/run/ci-keys/"
assert_eq "dir trailing slash norm"  "$(secrets_keyfile dev /w/ci/secrets.dev.enc.yaml)"   "/run/ci-keys/dev.age"
AGE_KEY_DIR=""
assert_eq "no AGE_KEY_DIR -> empty"  "$(secrets_keyfile dev /w/ci/secrets.dev.enc.yaml)"   ""
# key_present reflects a loaded (non-empty) file
KP="$W/kp.age"; : > "$KP"
assert_fail "empty key file -> not present" key_present "$KP"
printf 'AGE-SECRET-KEY-1x\n' > "$KP"
assert_ok   "non-empty key file -> present" key_present "$KP"

rm -rf "$W"
summary