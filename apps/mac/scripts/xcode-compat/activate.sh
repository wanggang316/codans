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
# still lists `<arch>-macos`, else a patched copy of the newest one, see
# xcode_compat_synthesize_sdk) and prepend bin/ to PATH, so that bin/xcrun
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

# Prints the newest installed versioned SDK older than <name> (for example
# MacOSX27.0.sdk), if any.
xcode_compat_older_sdk() {
  local current platform sdk version
  current="${1#MacOSX}"
  current="${current%.sdk}"
  platform="$(/usr/bin/xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null || true)"
  for sdk in "${platform}"/Developer/SDKs/MacOSX[0-9]*.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk; do
    [ -d "${sdk}" ] && [ ! -L "${sdk}" ] || continue
    version="${sdk##*/MacOSX}"
    version="${version%.sdk}"
    [ "$(printf '%s\n%s\n' "${version}" "${current}" | LC_ALL=C sort -V | head -n 1)" = "${version}" ] &&
      [ "${version}" != "${current}" ] || continue
    printf '%s\t%s\n' "${version}" "${sdk}"
  done | LC_ALL=C sort -t "$(printf '\t')" -k1,1V | tail -n 1 | cut -f 2
}

# Prints a copy of <sdk> whose .tbd stubs also list `<arch>-macos` wherever
# they list `<arch>e-macos`. Apple's linker links arm64 against the arm64e
# stubs; the copy only states that for zig. The copy is an APFS clone under
# apps/mac/.build/sdk-compat and is made once per SDK.
xcode_compat_synthesize_sdk() {
  local sdk="$1" arch="$2" dest stamp
  dest="${xcode_compat_dir}/../../.build/sdk-compat/$(basename "${sdk}")"
  stamp="${dest}/.codans-sdk-compat-${arch}"
  if [ ! -f "${stamp}" ]; then
    rm -rf "${dest}"
    mkdir -p "$(dirname "${dest}")"
    cp -cR "${sdk}" "${dest}" 2>/dev/null || cp -R "${sdk}" "${dest}" || return 1
    find "${dest}" -name '*.tbd' -print0 |
      xargs -0 perl -pi -e "s/\\b${arch}e-macos\\b/${arch}-macos, ${arch}e-macos/ if /\\b${arch}e-macos\\b/ && !/\\b${arch}-macos\\b/" ||
      return 1
    touch "${stamp}"
  fi
  (cd "${dest}" && pwd)
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
  if [ -z "${fallback}" ] && [ "${arch}" = "arm64" ]; then
    # No installed SDK lists arm64-macos: patch a copy of the newest
    # installed SDK older than the stock one. Zig 0.15.2 cannot build its
    # libc++ against the macOS 27 headers, so the stock SDK is the last
    # resort.
    local base
    base="$(xcode_compat_older_sdk "$(basename "${sdk}")")"
    [ -n "${base}" ] || base="$(cd "${sdk}" && pwd -P)"
    fallback="$(xcode_compat_synthesize_sdk "${base}" "${arch}")" || fallback=""
  fi
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
