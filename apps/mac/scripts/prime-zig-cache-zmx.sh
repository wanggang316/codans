#!/usr/bin/env bash
# Populate Zig's global cache with zmx's deps (ghostty + its transitive
# tarballs), bypassing Zig's HTTP client.
#
# Why: Zig 0.15.2's std.http.Client cannot complete GitHub's HTTP/2
# handshake (HttpConnectionClosing) and is also rejected by Cloudflare
# on deps.files.ghostty.org (400). curl's TLS is accepted in both cases.
# We therefore: (1) git-clone ghostty at the SHA zmx pins, strip .git so
# zig's content hash matches the value declared in zmx's build.zig.zon,
# then `zig fetch` the local directory into the cache; (2) for each
# tarball listed in ghostty's build.zig.zon.txt, curl it down and hand
# the LOCAL FILE to `zig fetch`. Same pattern as prime-zig-cache.sh,
# specialized for zmx's dep graph.
#
# Idempotent: skips entries already present in the cache.
# Usage:
#   ZIG_GLOBAL_CACHE_DIR=/path ./scripts/prime-zig-cache-zmx.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${srcroot}/../.." && pwd)"
zmx_dir="${srcroot}/ThirdParty/zmx"
cache_dir="${ZIG_GLOBAL_CACHE_DIR:?ZIG_GLOBAL_CACHE_DIR must be set}"

if [ ! -f "${zmx_dir}/build.zig.zon" ]; then
  echo "error: missing ${zmx_dir}/build.zig.zon; did you init the zmx submodule?" >&2
  exit 1
fi

mkdir -p "${cache_dir}/p"
tmp_dir="$(mktemp -d -t zig-prime-zmx)"
trap 'rm -rf "${tmp_dir}"' EXIT

zig_fetch() {
  mise exec -C "${repo_root}" -- zig fetch --global-cache-dir "${cache_dir}" "$@"
}

fetch_tarball() {
  # Pre-fetches a tarball into Zig's global cache via curl + `zig fetch`.
  # `zig fetch` itself is the cache-hit gate; this wrapper just bypasses
  # Zig's HTTP client.
  local url="$1"
  local tarball hash_name
  tarball="${tmp_dir}/$(basename "${url}")"
  curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --http1.1 "${url}" -o "${tarball}" || {
    echo "  curl failed: ${url}" >&2
    exit 1
  }
  hash_name="$(zig_fetch "${tarball}")" || exit 1
  rm -f "${tarball}"
  [ -n "${hash_name}" ] && [ -d "${cache_dir}/p/${hash_name}" ] || {
    echo "  zig fetch produced no ${cache_dir}/p/${hash_name:-<empty>}" >&2
    exit 1
  }
}

fetch_git_as_path() {
  # git+https://host/owner/repo[?query]#<rev>; clone, checkout, strip
  # .git so the zig manifest hash matches the value pinned in the
  # consuming zon. Echoes the cache hash on success.
  local spec="${1#git+}"
  local url_base rev checkout hash_name
  url_base="${spec%%#*}"
  url_base="${url_base%%\?*}"
  rev="${spec##*#}"
  checkout="${tmp_dir}/git-$(basename "${url_base%.git}")-$$"
  git clone --quiet "${url_base}" "${checkout}" || exit 1
  git -C "${checkout}" fetch --quiet origin "${rev}" 2>/dev/null || true
  git -C "${checkout}" -c advice.detachedHead=false checkout --quiet "${rev}" || exit 1
  rm -rf "${checkout}/.git"
  hash_name="$(zig_fetch "${checkout}")" || exit 1
  rm -rf "${checkout}"
  [ -n "${hash_name}" ] && [ -d "${cache_dir}/p/${hash_name}" ] || {
    echo "  zig fetch produced no ${cache_dir}/p/${hash_name:-<empty>}" >&2
    exit 1
  }
  printf '%s\n' "${hash_name}"
}

# Step 1: prime ghostty (zmx's only declared dep) from a git checkout.
ghostty_url="$(awk -F'"' '/git\+https:\/\/github.com\/ghostty-org\/ghostty/ {print $2; exit}' "${zmx_dir}/build.zig.zon")"
if [ -z "${ghostty_url}" ]; then
  echo "error: could not find ghostty git URL in ${zmx_dir}/build.zig.zon" >&2
  exit 1
fi
echo "[ghostty] ${ghostty_url}"
ghostty_hash="$(fetch_git_as_path "${ghostty_url}")"
ghostty_cache="${cache_dir}/p/${ghostty_hash}"

# Step 2: prime each tarball ghostty depends on (per its build.zig.zon.txt).
zon_txt="${ghostty_cache}/build.zig.zon.txt"
if [ ! -f "${zon_txt}" ]; then
  echo "error: missing ${zon_txt}; ghostty layout changed" >&2
  exit 1
fi

total=0
while IFS= read -r url || [ -n "${url}" ]; do
  [ -z "${url}" ] && continue
  total=$((total + 1))
  echo "[${total}] ${url}"
  case "${url}" in
    git+*) fetch_git_as_path "${url}" >/dev/null ;;
    *)     fetch_tarball "${url}" ;;
  esac
done < "${zon_txt}"

echo "done: primed ghostty + ${total} transitive deps into ${cache_dir}/p/"
