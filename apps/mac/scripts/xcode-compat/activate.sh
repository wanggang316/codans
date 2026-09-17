# shellcheck shell=bash
# Sourced by the zig build scripts (build-ghostty.sh, build-zmx.sh).
#
# Zig 0.15.2 (pinned: ghostty's build.zig requires exactly this version)
# predates two toolchain changes in recent Xcode releases:
#
# 1. Xcode 26.5+ SDKs list only `arm64e-macos` in libSystem.tbd. Zig's
#    linker matches the target arch exactly (arm64), resolves no libSystem
#    symbols, and every zig link fails. bin/xcrun answers zig's SDK query
#    with an installed SDK that still lists `<arch>-macos`.
# 2. Xcode 26.6's libtool drops 64-bit Mach-O archive members that are not
#    8-byte aligned, with only a warning. Zig's archiver does not align
#    members, so ghostty's libtool merge loses objects and the app link
#    fails later with undefined symbols. bin/libtool flattens the input
#    archives to loose objects first.
#
# xcode_compat_activate probes for both and exports the env var that
# switches on the matching wrapper; bin/ is prepended to PATH only when at
# least one is needed. Without their env var the wrappers forward to the
# real tools, which keeps processes that inherit PATH alone (ghostty's
# inner xcodebuild) on the stock toolchain.

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

# Succeeds when libtool loses an archive member that starts at an unaligned
# offset. Any probe failure also counts as "drops": flattening is always a
# safe way to merge, so a broken probe only costs the extra work.
xcode_compat_libtool_drops_unaligned() {
  local work status=0
  work="$(mktemp -d "${TMPDIR:-/tmp}/xcode-compat.XXXXXX")"
  (
    cd "${work}" || exit 1
    printf 'int xcode_compat_probe(void) { return 0; }\n' > probe.c
    /usr/bin/xcrun clang -c probe.c -o probe.o || exit 1
    size="$(stat -f %z probe.o)"
    # A single short-name member right after the 8-byte magic has its data
    # at offset 68, which is not 8-byte aligned: the layout zig produces.
    {
      printf '!<arch>\n'
      printf '%-16s%-12s%-6s%-6s%-8s%-10s`\n' probe.o 0 0 0 100644 "${size}"
      cat probe.o
      [ $((size % 2)) -eq 0 ] || printf '\n'
    } > probe.a
    /usr/bin/libtool -static -o merged.a probe.a 2>/dev/null || exit 1
    /usr/bin/nm merged.a 2>/dev/null | grep -q '_xcode_compat_probe'
  ) || status=$?
  rm -rf "${work}"
  [ "${status}" -ne 0 ]
}

xcode_compat_activate() {
  local arch sdk fallback
  unset CODANS_ZIG_MACOS_SDK CODANS_LIBTOOL_FLATTEN
  arch="$(uname -m)"
  sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"

  if ! xcode_compat_sdk_links_arch "${sdk}" "${arch}"; then
    fallback="$(xcode_compat_find_sdk "${arch}")"
    if [ -z "${fallback}" ]; then
      echo "error: zig cannot link against ${sdk} (its libSystem.tbd lists no ${arch}-macos target)," >&2
      echo "error: and no other installed macOS SDK can be used instead." >&2
      echo "error: Install Command Line Tools that include an older SDK (e.g. MacOSX15.4.sdk)." >&2
      return 1
    fi
    echo "xcode-compat: zig uses ${fallback} (${sdk} lists no ${arch}-macos libSystem)" >&2
    export CODANS_ZIG_MACOS_SDK="${fallback}"
  fi

  if xcode_compat_libtool_drops_unaligned; then
    echo "xcode-compat: libtool drops unaligned archive members; flattening archives before merging" >&2
    export CODANS_LIBTOOL_FLATTEN=1
  fi

  if [ -n "${CODANS_ZIG_MACOS_SDK:-}" ] || [ -n "${CODANS_LIBTOOL_FLATTEN:-}" ]; then
    export PATH="${xcode_compat_dir}/bin:${PATH}"
  fi
}
