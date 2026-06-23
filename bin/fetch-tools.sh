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
# sq (SQL over JSON) — powers ci-status analytics. OPTIONAL: the runner never needs it;
# ci-status degrades to its dependency-light view if absent. Asset name varies by release,
# so resolve the real linux/<arch> tarball via the GitHub API; never fatal.
if ! have sq; then
  echo "→ sq (neilotoole, latest, $A) [optional: ci-status analytics]"
  tmp="$(mktemp -d)"
  url="$(curl -fsSL https://api.github.com/repos/neilotoole/sq/releases/latest 2>/dev/null \
         | grep -oE 'https://[^"]+linux[._-]'"$A"'\.tar\.gz' | head -1)"
  if [ -n "$url" ] && curl -fsSL "$url" -o "$tmp/sq.tgz" && tar xzf "$tmp/sq.tgz" -C "$tmp" 2>/dev/null; then
    f="$(find "$tmp" -type f -name sq | head -1)"
    [ -n "$f" ] && install -m755 "$f" "$BIN/sq" && echo "  sq -> $BIN/sq"
  fi
  command -v "$BIN/sq" >/dev/null 2>&1 || have sq || \
    echo "  (sq not installed — analytics optional; grab it from https://sq.io into $BIN)"
  rm -rf "$tmp"
fi

echo "--- $BIN ---"; ls -1 "$BIN"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "NOTE: $BIN not on PATH. Add it:"
     echo "      echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.bash_profile && . ~/.bash_profile" ;;
esac
