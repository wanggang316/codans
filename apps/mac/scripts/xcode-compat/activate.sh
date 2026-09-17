# shellcheck shell=bash
# Sourced by the zig build scripts (build-ghostty.sh, build-zmx.sh).
#
# Xcode 26.4+ SDKs list only `arm64e-macos` in libSystem.tbd. Zig 0.15.2
# (pinned: ghostty's build.zig requires exactly this version) matches the
# target arch exactly (arm64), resolves no libSystem symbols, and every zig
# link fails. The fix (ziglang/zig#31673) shipped only in zig 0.16.0.
#
# xcode_compat_activate checks the SDK zig would use. Only when that SDK
# cannot link does it export CODANS_ZIG_MACOS_SDK (an installed SDK that
# still lists `<arch>-macos`) and prepend bin/ to PATH, so that bin/xcrun
# answers zig's SDK query with it. Without the variable bin/xcrun forwards to
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

# Prints the newest installed macOS SDK that can link <arch>, if any.
xcode_compat_find_sdk() {
  local platform sdk
  platform="$(/usr/bin/xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null || true)"
  for sdk in "${platform}"/Developer/SDKs/MacOSX*.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk; do
    [ -d "${sdk}" ] || continue
    xcode_compat_sdk_links_arch "${sdk}" "$1" || continue
    local version="${sdk##*/MacOSX}"
    printf '%s\t%s\n' "${version%.sdk}" "${sdk}"
  done | LC_ALL=C sort -t "$(printf '\t')" -k1,1V | tail -n 1 | cut -f 2
}

xcode_compat_activate() {
  local arch sdk fallback
  unset CODANS_ZIG_MACOS_SDK
  arch="$(uname -m)"
  sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
  if xcode_compat_sdk_links_arch "${sdk}" "${arch}"; then
    return 0
  fi

  fallback="$(xcode_compat_find_sdk "${arch}")"
  if [ -z "${fallback}" ]; then
    echo "error: zig cannot link against ${sdk} (its libSystem.tbd lists no ${arch}-macos target)," >&2
    echo "error: and no other installed macOS SDK can be used instead." >&2
    echo "error: Install Command Line Tools that include an older SDK (e.g. MacOSX15.4.sdk)." >&2
    return 1
  fi
  echo "xcode-compat: zig uses ${fallback} (${sdk} lists no ${arch}-macos libSystem)" >&2
  export CODANS_ZIG_MACOS_SDK="${fallback}"
  export PATH="${xcode_compat_dir}/bin:${PATH}"
}
