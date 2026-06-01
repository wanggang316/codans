#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/$(basename "${BASH_SOURCE[0]}")"
srcroot="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"
repo_root="$(cd "${srcroot}/../.." && pwd)"
ghostty_dir="${srcroot}/ThirdParty/ghostty"
ghostty_submodule_path="${ghostty_dir#"${repo_root}/"}"
ghostty_build_root="${srcroot}/.build/ghostty"
ghostty_local_cache_dir="${ghostty_build_root}/.zig-cache"
ghostty_global_cache_dir="${ghostty_build_root}/.zig-global-cache"
ghostty_fingerprint_path="${ghostty_build_root}/fingerprint"
ghostty_legacy_prefix_path="${ghostty_dir}/zig-out"
ghostty_legacy_share_path="${ghostty_legacy_prefix_path}/share"
xcframework_path="${ghostty_build_root}/GhosttyKit.xcframework"
ghostty_resources_path="${ghostty_build_root}/share/ghostty"
ghostty_terminfo_path="${ghostty_build_root}/share/terminfo"

print_fingerprint() {
  (
    cd "${ghostty_dir}"
    {
      git rev-parse HEAD
      git diff --no-ext-diff --no-color HEAD -- . | shasum -a 256
      git ls-files --others --exclude-standard | LC_ALL=C sort | shasum -a 256
      shasum -a 256 "${script_path}" | awk '{print $1}'
      shasum -a 256 "${repo_root}/mise.toml" | awk '{print $1}'
    } | shasum -a 256 | awk '{print $1}'
  )
}

prepare_xcframework() {
  local modulemap
  find "${xcframework_path}" -path '*/Headers/module.modulemap' -print0 | while IFS= read -r -d '' modulemap; do
    cat > "${modulemap}" <<'EOF'
module GhosttyKit {
    header "ghostty.h"
    export *
}
EOF
  done
  dedupe_xcframework_headers
}

# Xcode's `builtin-process-xcframework` rejects an xcframework whose Headers
# tree carries two files with the same basename: it builds a flat basename map,
# loses the collided entry, and then fails with `The file "X" doesn't exist`.
# The vt headers ship both `key/{event,encoder}.h` and `mouse/{event,encoder}.h`,
# so the mouse-side pair collides. Rename the mouse-side files to unique
# basenames and rewrite the (path-qualified) `#include`s that reference them.
# Symbol names are untouched — only header file paths change — so consumers
# that import the GhosttyKit module are unaffected. Idempotent: the `-f` guards
# skip a slice that was already deduplicated.
dedupe_xcframework_headers() {
  local vt hdr
  find "${xcframework_path}" -type d -path '*/Headers/ghostty/vt' -print0 |
    while IFS= read -r -d '' vt; do
      [ -f "${vt}/mouse/event.h" ] && mv "${vt}/mouse/event.h" "${vt}/mouse/mouse_event.h"
      [ -f "${vt}/mouse/encoder.h" ] && mv "${vt}/mouse/encoder.h" "${vt}/mouse/mouse_encoder.h"
      for hdr in "${vt}/mouse.h" "${vt}/mouse/mouse_encoder.h"; do
        [ -f "${hdr}" ] || continue
        sed -i '' \
          -e 's#ghostty/vt/mouse/event.h#ghostty/vt/mouse/mouse_event.h#g' \
          -e 's#ghostty/vt/mouse/encoder.h#ghostty/vt/mouse/mouse_encoder.h#g' \
          "${hdr}"
      done
    done
}

ensure_ghostty_checkout() {
  if [ -f "${ghostty_dir}/build.zig" ]; then
    return
  fi

  git -C "${repo_root}" submodule sync --recursive -- "${ghostty_submodule_path}"
  git -C "${repo_root}" submodule update --init --recursive -- "${ghostty_submodule_path}"

  if [ ! -f "${ghostty_dir}/build.zig" ]; then
    echo "error: missing ${ghostty_dir} after submodule update" >&2
    exit 1
  fi
}

ensure_ghostty_checkout

if [ "${1:-}" = "--print-fingerprint" ]; then
  print_fingerprint
  exit 0
fi

fingerprint="$(print_fingerprint)"

rm -rf "${ghostty_legacy_prefix_path}"
mkdir -p "${ghostty_build_root}" "${ghostty_legacy_prefix_path}"
ln -s "${ghostty_build_root}/share" "${ghostty_legacy_share_path}"

if [ -f "${ghostty_fingerprint_path}" ] &&
  [ -d "${xcframework_path}" ] &&
  [ -d "${ghostty_resources_path}" ] &&
  [ -d "${ghostty_terminfo_path}" ] &&
  [ "$(cat "${ghostty_fingerprint_path}")" = "${fingerprint}" ]; then
  exit 0
fi

# Zig 0.15.2's std.http.Client TLS handshake is rejected by Cloudflare on
# deps.files.ghostty.org (400). Prime the global cache via curl first; the
# prime script is idempotent (skips already-cached entries) so it's cheap
# on rebuilds and mandatory on cold builds.
ZIG_GLOBAL_CACHE_DIR="${ghostty_global_cache_dir}" "${script_dir}/prime-zig-cache.sh"

cd "${ghostty_dir}"
# -Dxcframework-target=native produces a single-arch slice matching the
# host CPU (arm64 on Apple Silicon) and tells ghostty's build.zig to pass
# -arch arm64 to the inner `xcodebuild -target Ghostty` invocation.
# Without this, Zig defaults to universal, and the inner xcodebuild
# tries to build DockTilePlugin for x86_64 — libghostty's bundled imgui
# has missing symbols on x86_64, which fails the link on a cold CI
# runner. (Locally it was always warm-cached.) Setting ARCHS via env
# doesn't help: ghostty's GhosttyXcodebuild.zig deliberately strips the
# environment before spawning xcodebuild ("External environment
# variables can mess up xcodebuild"). We ship arm64-only anyway, so the
# x86_64 slice would be wasted weight.
mise exec -- zig build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Dxcframework-target=native \
  -Dsentry=false \
  --prefix "${ghostty_build_root}" \
  --cache-dir "${ghostty_local_cache_dir}" \
  --global-cache-dir "${ghostty_global_cache_dir}"
rsync -a --delete "${ghostty_dir}/macos/GhosttyKit.xcframework/" "${xcframework_path}/"
prepare_xcframework
printf '%s\n' "${fingerprint}" > "${ghostty_fingerprint_path}"
