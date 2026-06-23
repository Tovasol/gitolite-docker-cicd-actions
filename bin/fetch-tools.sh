#!/usr/bin/env sh
# fetch-tools.sh — install the CI/CD STACK's own tools (Domain A), PINNED + sha256-VERIFIED
# + CACHED. Single version each, so no version collision and no package-manager machinery.
# NOT for per-repo build deps (wrangler/tsc/… live in the ephemeral job container).
# (Note: the shellcheck linter is NOT listed below — it comes from the distro package
#  manager, apt/emerge, already integrity-verified there.)
#
#   usage: fetch-tools.sh [tool ...]      # default: all tools for this arch
#   env:   CICD_TOOLS_DIR  install dir (default ~/.local/bin). Point at /cache/tools on a
#                          persistent volume to cache across ephemeral CI runs.
set -eu

DEST="${CICD_TOOLS_DIR:-$HOME/.local/bin}"; mkdir -p "$DEST"
arch="$(uname -m)"; case "$arch" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac
want="$*"

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
fetch() { if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"; else wget -qO "$2" "$1"; fi; }

n_ok=0; n_cached=0
# The loop reads its manifest from the heredoc at the bottom. Columns are whitespace-
# separated: <name> <arch> <url> <sha256> <format>. Comment/blank lines are skipped.
while read -r name a url sha fmt; do
  case "$name" in ''|\#*) continue ;; esac
  [ "$a" = "$arch" ] || continue
  [ -z "$want" ] || case " $want " in *" $name "*) ;; *) continue ;; esac

  out="$DEST/$name"; marker="$DEST/.$name.sha"
  # cache: a present binary whose recorded source-sha matches the pin -> skip (no download)
  if [ -x "$out" ] && [ "$(cat "$marker" 2>/dev/null || true)" = "$sha" ]; then
    n_cached=$((n_cached + 1)); echo "  cached    $name"; continue
  fi

  tmp="$(mktemp)"
  fetch "$url" "$tmp"
  got="$(sha_of "$tmp")"
  [ "$got" = "$sha" ] || { echo "fetch-tools: SHA256 MISMATCH for $name ($arch)" >&2; \
    echo "  expected $sha" >&2; echo "  got      $got" >&2; rm -f "$tmp"; exit 1; }

  case "$fmt" in
    bin)      install -m755 "$tmp" "$out" ;;
    zip:*)    d="$(mktemp -d)"; unzip -oq "$tmp" -d "$d"; install -m755 "$d/${fmt#zip:}"   "$out"; rm -rf "$d" ;;
    targz:*)  d="$(mktemp -d)"; tar -xzf "$tmp" -C "$d";  install -m755 "$d/${fmt#targz:}" "$out"; rm -rf "$d" ;;
    tarxz:*)  d="$(mktemp -d)"; tar -xJf "$tmp" -C "$d";  install -m755 "$d/${fmt#tarxz:}" "$out"; rm -rf "$d" ;;
    *) echo "fetch-tools: unknown format '$fmt' for $name" >&2; rm -f "$tmp"; exit 1 ;;
  esac
  rm -f "$tmp"; printf '%s' "$sha" > "$marker"
  n_ok=$((n_ok + 1)); echo "  installed $name (sha256 verified)"
done <<'TOOLS'
# ============================================================================
#  PACKAGES — add / update / remove tools here.  Whitespace-separated columns:
#    <name>  <arch:amd64|arm64>  <url>  <sha256>  <format>
#  format: bin | zip:<path-in-zip> | targz:<path-in-tgz> | tarxz:<path-in-txz>
#  To bump: change the version in the url AND paste the new sha256 (from that
#  release's published checksums). Both arches if you want arm support.
# ============================================================================
yq         amd64 https://github.com/mikefarah/yq/releases/download/v4.47.1/yq_linux_amd64 0fb28c6680193c41b364193d0c0fc4a03177aecde51cfc04d506b1517158c2fb bin
yq         arm64 https://github.com/mikefarah/yq/releases/download/v4.47.1/yq_linux_arm64 b7f7c991abe262b0c6f96bbcb362f8b35429cefd59c8b4c2daa4811f1e9df599 bin
duckdb     amd64 https://github.com/duckdb/duckdb/releases/download/v1.5.4/duckdb_cli-linux-amd64.zip 1f2fa724fb054b3dbe1a9cbd13de5b76997d850e7087ec762ba88db04e0180cf zip:duckdb
duckdb     arm64 https://github.com/duckdb/duckdb/releases/download/v1.5.4/duckdb_cli-linux-arm64.zip 377f03fb9f17ab5a78f28f829cbfcb5333da8ab3c2d0788f27694f81df77ed29 zip:duckdb
sops       amd64 https://github.com/getsops/sops/releases/download/v3.13.1/sops-v3.13.1.linux.amd64 620a9d7e3352ababeca6908cea24a6e8b14ce89a448ddbd3f94f1ef3398f470a bin
sops       arm64 https://github.com/getsops/sops/releases/download/v3.13.1/sops-v3.13.1.linux.arm64 19576fb1734dbf8fb77eda0cf0f3a2218f99bf4d33b814318e5e10d6babb9820 bin
age        amd64 https://github.com/FiloSottile/age/releases/download/v1.3.1/age-v1.3.1-linux-amd64.tar.gz bdc69c09cbdd6cf8b1f333d372a1f58247b3a33146406333e30c0f26e8f51377 targz:age/age
age-keygen amd64 https://github.com/FiloSottile/age/releases/download/v1.3.1/age-v1.3.1-linux-amd64.tar.gz bdc69c09cbdd6cf8b1f333d372a1f58247b3a33146406333e30c0f26e8f51377 targz:age/age-keygen
age        arm64 https://github.com/FiloSottile/age/releases/download/v1.3.1/age-v1.3.1-linux-arm64.tar.gz c6878a324421b69e3e20b00ba17c04bc5c6dab0030cfe55bf8f68fa8d9e9093a targz:age/age
age-keygen arm64 https://github.com/FiloSottile/age/releases/download/v1.3.1/age-v1.3.1-linux-arm64.tar.gz c6878a324421b69e3e20b00ba17c04bc5c6dab0030cfe55bf8f68fa8d9e9093a targz:age/age-keygen
TOOLS

echo "fetch-tools: $n_ok installed, $n_cached cached  ->  $DEST"
case ":$PATH:" in *":$DEST:"*) ;; *) echo "  (add $DEST to PATH)" ;; esac
