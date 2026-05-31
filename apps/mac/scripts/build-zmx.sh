#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/$(basename "${BASH_SOURCE[0]}")"
srcroot="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"
repo_root="$(cd "${srcroot}/../.." && pwd)"
zmx_dir="${srcroot}/ThirdParty/zmx"
zmx_submodule_path="${zmx_dir#"${repo_root}/"}"
zmx_build_root="${srcroot}/.build/zmx"
zmx_local_cache_dir="${zmx_build_root}/.zig-cache"
zmx_global_cache_dir="${zmx_build_root}/.zig-global-cache"
zmx_fingerprint_path="${zmx_build_root}/.fingerprint"
zmx_binary_path="${zmx_build_root}/bin/zmx"

print_fingerprint() {
  (
    cd "${zmx_dir}"
    {
      git rev-parse HEAD
      git diff --no-ext-diff --no-color HEAD -- . | shasum -a 256
      git ls-files --others --exclude-standard | LC_ALL=C sort | shasum -a 256
      shasum -a 256 "${script_path}" | awk '{print $1}'
      shasum -a 256 "${repo_root}/mise.toml" | awk '{print $1}'
    } | shasum -a 256 | awk '{print $1}'
  )
}

ensure_zmx_checkout() {
  if [ -f "${zmx_dir}/build.zig" ]; then
    return
  fi

  git -C "${repo_root}" submodule sync --recursive -- "${zmx_submodule_path}"
  git -C "${repo_root}" submodule update --init --recursive -- "${zmx_submodule_path}"

  if [ ! -f "${zmx_dir}/build.zig" ]; then
    echo "error: missing ${zmx_dir} after submodule update" >&2
    exit 1
  fi
}

ensure_zmx_checkout

if [ "${1:-}" = "--print-fingerprint" ]; then
  print_fingerprint
  exit 0
fi

fingerprint="$(print_fingerprint)"

mkdir -p "${zmx_build_root}"

if [ -f "${zmx_fingerprint_path}" ] &&
  [ -x "${zmx_binary_path}" ] &&
  [ "$(cat "${zmx_fingerprint_path}")" = "${fingerprint}" ]; then
  echo "build-zmx: fingerprint matched, skipping"
  exit 0
fi

# Zig 0.15.2's std.http.Client cannot complete GitHub's HTTP/2 handshake
# and is rejected by Cloudflare on deps.files.ghostty.org. Prime the
# global cache via curl + `zig fetch` first; the prime script is
# idempotent and a no-op on cache hits. Same pattern as build-ghostty.sh.
ZIG_GLOBAL_CACHE_DIR="${zmx_global_cache_dir}" "${script_dir}/prime-zig-cache-zmx.sh"

# Resolve zig via the top-level mise.toml. zmx ships its own mise.toml,
# which would require a per-worktree `mise trust` to evaluate — bypass it
# by resolving the binary at the repo root and invoking it directly.
zig_bin="$(cd "${repo_root}" && mise which zig)"

cd "${zmx_dir}"
"${zig_bin}" build \
  -Doptimize=ReleaseSafe \
  --prefix "${zmx_build_root}" \
  --cache-dir "${zmx_local_cache_dir}" \
  --global-cache-dir "${zmx_global_cache_dir}"

if [ ! -x "${zmx_binary_path}" ]; then
  echo "error: ${zmx_binary_path} missing after zig build" >&2
  exit 1
fi

printf '%s\n' "${fingerprint}" > "${zmx_fingerprint_path}"
