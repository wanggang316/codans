# shellcheck shell=bash
# Sourced by the zig build scripts (build-ghostty.sh, build-zmx.sh).
#
# Xcode 26.4+ SDKs list only `arm64e-macos` (no `arm64-macos`) in their text
# stubs (.tbd). Apple's ld links arm64 code against arm64e stubs. Zig 0.15.2
# (pinned: ghostty's build.zig requires exactly this version) matches the
# target arch exactly, resolves no libSystem symbols, and every zig link
# fails. The fix (ziglang/zig#31673) shipped only in zig 0.16.0.
#
# xcode_compat_activate checks the SDK zig would use. Only when that SDK
# cannot link does it build a view of the same SDK whose stubs also list
# `arm64-macos` (everything else links to the real SDK), export it as
# CODANS_ZIG_MACOS_SDK, and prepend bin/ to PATH, so that bin/xcrun answers
# zig's SDK query with the view. Without the variable bin/xcrun forwards to
# the real xcrun, which keeps processes that inherit PATH alone (ghostty's
# inner xcodebuild) on the stock SDK.

xcode_compat_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prints a hash of this directory's contents, for build fingerprints.
xcode_compat_fingerprint() {
  find "${xcode_compat_dir}" -type f ! -name '.*' -print0 | LC_ALL=C sort -z | xargs -0 cat |
    shasum -a 256 | awk '{print $1}'
}

# Succeeds when the SDK's libSystem.tbd lists `<arch>-macos` as a target.
xcode_compat_sdk_links_arch() {
  local tbd="$1/usr/lib/libSystem.tbd"
  [ -f "${tbd}" ] || return 1
  # The top-level `targets:` list may wrap; read through its closing `]`.
  awk '/^targets:/ { on = 1 } on { print } on && /\]/ { exit }' "${tbd}" |
    grep -qw -- "$2-macos"
}

# Usage: xcode_compat_activate <cache-dir>
# The view is built once per SDK under <cache-dir> and reused.
xcode_compat_activate() {
  local cache_dir="$1" arch sdk stamp view tmp
  unset CODANS_ZIG_MACOS_SDK
  arch="$(uname -m)"
  sdk="$(cd "$(/usr/bin/xcrun --sdk macosx --show-sdk-path)" && pwd -P)"
  if xcode_compat_sdk_links_arch "${sdk}" "${arch}"; then
    return 0
  fi
  if [ "${arch}" != "arm64" ]; then
    echo "error: zig cannot link against ${sdk} (its libSystem.tbd lists no ${arch}-macos target)." >&2
    return 1
  fi

  # An Xcode update can replace the SDK in place, so the key also covers
  # the libSystem stub's contents and this script.
  stamp="$(
    {
      printf '%s\n' "${sdk}"
      shasum -a 256 "${sdk}/usr/lib/libSystem.B.tbd"
      xcode_compat_fingerprint
    } | shasum -a 256 | cut -c1-16
  )"
  view="${cache_dir}/${stamp}/$(basename "${sdk}")"
  if [ ! -d "${view}" ]; then
    mkdir -p "${cache_dir}"
    tmp="$(mktemp -d "${cache_dir}/.tmp.XXXXXX")"
    "${xcode_compat_dir}/sdk-view.pl" "${sdk}" "${tmp}/$(basename "${sdk}")"
    mkdir -p "${cache_dir}/${stamp}"
    # Another build may have finished the same view first; keep that one.
    mv "${tmp}/$(basename "${sdk}")" "${view}" 2>/dev/null || true
    rm -rf "${tmp}"
  fi
  echo "xcode-compat: zig uses ${view} (${sdk} lists no ${arch}-macos libSystem)" >&2
  export CODANS_ZIG_MACOS_SDK="${view}"
  export PATH="${xcode_compat_dir}/bin:${PATH}"
}
