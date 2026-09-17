#!/usr/bin/env bash
# Warm-cache regression test for xcode-compat/activate.sh.
#
# Zig's Run step cache keys on a step's argv and input files, not on PATH or
# the environment. A fixture that calls `libtool` the way ghostty's
# LibtoolStep does first caches the output of a stand-in "broken" libtool,
# then switches the flattening wrapper on. Without xcode_compat_sync_cache
# zig reuses the stale output; with it, zig re-runs the step. Also checks
# that an unchanged mode keeps the cache and that switching back clears it.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"
zig_bin="$(cd "${repo_root}" && mise which zig)"

# shellcheck source=xcode-compat/activate.sh
source "${script_dir}/xcode-compat/activate.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/xcode-compat-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
cache_dir="${work}/zig-cache"
base_path="${PATH}"
failures=0

mkdir -p "${work}/project" "${work}/broken-bin"
cat > "${work}/broken-bin/libtool" <<'EOF'
#!/bin/bash
# Stands in for a libtool that loses objects: writes a marker, no archive.
printf 'broken libtool\n' > "$3"
EOF
chmod +x "${work}/broken-bin/libtool"

(
  cd "${work}/project"
  printf 'int xcode_compat_fixture(void) { return 0; }\n' > fixture.c
  /usr/bin/xcrun clang -c fixture.c -o fixture.o
  /usr/bin/ar rcs input.a fixture.o
)
cat > "${work}/project/build.zig" <<'EOF'
const std = @import("std");

// Mirrors ghostty's src/build/LibtoolStep.zig.
pub fn build(b: *std.Build) void {
    const run = b.addSystemCommand(&.{ "libtool", "-static", "-o" });
    const merged = run.addOutputFileArg("merged.a");
    run.addFileArg(b.path("input.a"));
    b.getInstallStep().dependOn(&b.addInstallFile(merged, "merged.a").step);
}
EOF

# The fixture's build runner is itself linked by zig, so keep whatever SDK
# redirect this machine needs; only the libtool mode varies below.
xcode_compat_activate "${work}/probe-cache" 2>/dev/null
sdk_mode="${CODANS_ZIG_MACOS_SDK:-}"

# Usage: build <broken|flatten> <sync|nosync>; sets `cleared` to yes/no.
build() {
  unset CODANS_LIBTOOL_FLATTEN
  export CODANS_ZIG_MACOS_SDK="${sdk_mode}"
  local path="${work}/broken-bin:${xcode_compat_dir}/bin:${base_path}"
  if [ "$1" = flatten ]; then
    export CODANS_LIBTOOL_FLATTEN=1
    path="${xcode_compat_dir}/bin:${work}/broken-bin:${base_path}"
  fi
  cleared=no
  if [ "$2" = sync ]; then
    local log
    log="$(xcode_compat_sync_cache "${cache_dir}" 2>&1)"
    case "${log}" in *clearing*) cleared=yes ;; esac
  fi
  rm -rf "${work}/out"
  (
    cd "${work}/project"
    PATH="${path}" "${zig_bin}" build --prefix "${work}/out" \
      --cache-dir "${cache_dir}" --global-cache-dir "${work}/zig-global-cache"
  )
}

output_kind() {
  local merged="${work}/out/merged.a"
  if grep -q 'broken libtool' "${merged}"; then
    echo broken
  elif /usr/bin/nm "${merged}" 2>/dev/null | grep -q '_xcode_compat_fixture'; then
    echo flattened
  else
    echo unknown
  fi
}

# Usage: expect <label> <output kind> <cleared>
expect() {
  local kind
  kind="$(output_kind)"
  if [ "${kind}" = "$2" ] && [ "${cleared}" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: output=${kind} cleared=${cleared}, want output=$2 cleared=$3"
    failures=$((failures + 1))
  fi
}

build broken sync
expect "broken libtool populates the cache" broken no

# Control: proves the fixture hits the Run step cache. If zig ever keys the
# step on PATH or the environment, this fails and the sync may be removable.
build flatten nosync
expect "zig alone reuses the stale output" broken no

build flatten sync
expect "switching the wrapper on clears the cache" flattened yes

build flatten sync
expect "an unchanged mode keeps the cache" flattened no

build broken sync
expect "switching the wrapper off clears the cache" broken yes

if [ "${failures}" -ne 0 ]; then
  echo "${failures} check(s) failed" >&2
  exit 1
fi
