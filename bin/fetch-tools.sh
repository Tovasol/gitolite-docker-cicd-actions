#!/usr/bin/env bash
# fetch-tools.sh — download sops, yq, age into ~/.local/bin. No root, no /usr/local,
# no emerge. Fully user-local. Skips anything already on PATH. Arch-aware (amd64/arm64).
set -euo pipefail

BIN="${LOCAL_BIN:-$HOME/.local/bin}"; mkdir -p "$BIN"
case "$(uname -m)" in
  x86_64|amd64) A=amd64 ;;
  aarch64|arm64) A=arm64 ;;
  *) echo "unsupported arch $(uname -m) — fetch sops/yq/age manually into $BIN"; exit 1 ;;
esac
SOPS_VER=v3.13.1
have() { command -v "$1" >/dev/null 2>&1; }

if ! have sops; then
  echo "→ sops $SOPS_VER ($A)"
  curl -fsSL "https://github.com/getsops/sops/releases/download/$SOPS_VER/sops-$SOPS_VER.linux.$A" -o "$BIN/sops"
  chmod +x "$BIN/sops"
fi
if ! have yq; then
  echo "→ yq (mikefarah, latest, $A)"
  curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$A" -o "$BIN/yq"
  chmod +x "$BIN/yq"
fi
if ! have age-keygen; then
  echo "→ age (latest, $A)"
  tmp="$(mktemp -d)"
  curl -fsSL "https://dl.filippo.io/age/latest?for=linux/$A" | tar xz -C "$tmp"
  install -m755 "$tmp"/age/age "$tmp"/age/age-keygen "$BIN/"
  rm -rf "$tmp"
fi
# duckdb — powers ci-status analytics (reads the run meta.json files directly via a native
# glob; no concat/cache plumbing). OPTIONAL: the runner core never needs it; ci-status
# degrades to its dependency-light view if absent. Single static binary in a .zip.
if ! have duckdb; then
  case "$A" in amd64) da=amd64 ;; arm64) da=aarch64 ;; *) da="$A" ;; esac
  echo "→ duckdb (latest, linux-$da) [optional: ci-status analytics]"
  tmp="$(mktemp -d)"
  url="https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-$da.zip"
  if command -v unzip >/dev/null 2>&1 && curl -fsSL "$url" -o "$tmp/d.zip" \
     && unzip -o "$tmp/d.zip" -d "$tmp" >/dev/null 2>&1 && [ -f "$tmp/duckdb" ]; then
    install -m755 "$tmp/duckdb" "$BIN/duckdb" && echo "  duckdb -> $BIN/duckdb"
  fi
  command -v "$BIN/duckdb" >/dev/null 2>&1 || have duckdb || \
    echo "  (duckdb not installed — analytics optional; needs unzip+network, or emerge dev-db/duckdb / https://duckdb.org)"
  rm -rf "$tmp"
fi

echo "--- $BIN ---"; ls -1 "$BIN"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "NOTE: $BIN not on PATH. Add it:"
     echo "      echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.bash_profile && . ~/.bash_profile" ;;
esac
