# Lessons Learned: zig builds broke on Xcode 26.5 / 26.6

**Status:** Resolved
**Date:** 2026-09-17
**Area:** Build toolchain (`build-ghostty.sh`, `build-zmx.sh`, `apps/mac/scripts/xcode-compat/`)
**Fix:** branch `build/xcode26-zig-compat` — `build(mac): let zig 0.15.2 build on Xcode 26.5+`

## Summary

On a Mac with Xcode 26.6, a cold `make mac-build` failed twice, at two
different stages, while CI (pinned to Xcode 26.0) stayed green. First, every
zig link in the ghostty and zmx builds failed with undefined libc symbols.
Once that was worked around, ghostty's inner `xcodebuild` failed to link
`libghostty-fat.a` with undefined symbols from ghostty's C dependencies
(`imgui_draw`, oniguruma encodings, …). Upgrading zig was not an option:
ghostty's `build.zig` accepts only zig 0.15.2. Zig 0.16.0 links against the
new SDK but ghostty rejects it.

## Root cause

1. **The SDK's libSystem stubs are arm64e-only (Xcode 26.5+).** The macOS
   26.5 SDK's `usr/lib/libSystem.tbd` declares
   `targets: [ x86_64-macos, x86_64-maccatalyst, arm64e-macos, arm64e-maccatalyst ]`.
   Apple's `ld` accepts arm64e stubs when it links arm64, but zig 0.15.2's
   linker requires an exact `arm64-macos` match, finds no usable libSystem,
   and reports every libc symbol as undefined. Even a minimal program fails:

   ```
   $ zig build-exe hello.zig -lc
   error: undefined symbol: _abort
   ```

   Zig locates the SDK only through `xcrun --sdk macosx --show-sdk-path`
   (`std/zig/system/darwin.zig`). The Command Line Tools on the same machine
   still ship `MacOSX15.4.sdk`, whose stubs list `arm64-macos`.

2. **libtool drops unaligned archive members (Xcode 26.6).** ghostty merges
   its static libraries with `libtool -static -o libghostty-fat.a <libs…>`
   (`src/build/LibtoolStep.zig`). Zig's archiver does not pad members to
   8-byte offsets, and the libtool in Xcode 26.6 (`cctools_ld-1267`) skips
   such members:

   ```
   libtool: warning: 64-bit mach-o member 'zutil.o' not 8-byte aligned
   ```

   libtool still exits 0, so the zig build reports success. Re-running the
   merge on the 14 archives in ghostty's zig cache kept 123 of 245 objects.
   The missing objects only showed up later, as undefined symbols at the app
   link.

## Fix

`apps/mac/scripts/xcode-compat/activate.sh` is sourced by both zig build
scripts. It runs just before `zig build`, only when the build fingerprint
misses, and probes the active toolchain:

- **SDK probe.** Does the resolved SDK's `libSystem.tbd` list
  `<arch>-macos`? If not, it picks the newest installed SDK that does (Xcode's
  platform directory, then the Command Line Tools) and exports
  `CODANS_ZIG_MACOS_SDK`. `bin/xcrun` returns that path for zig's exact query.
  If no installed SDK qualifies, the build stops with an explanation.
- **libtool probe.** Does libtool keep a one-member archive whose object
  starts at offset 68? If not, it exports `CODANS_LIBTOOL_FLATTEN=1`.
  `bin/libtool` then extracts each input archive and passes the loose objects
  to the real libtool, which writes them aligned. It refuses archives with
  repeated member names, because `ar x` would overwrite one with the other.
- `bin/` is prepended to PATH only when a probe fires, and each wrapper execs
  the real tool unless its variable is set. That gate matters: ghostty's
  inner `xcodebuild` inherits PATH but no other environment variables
  (`GhosttyXcodebuild.zig`), so it keeps the stock SDK and linker.

On Xcode 26.0 (CI) both probes pass and the build is unchanged. The
`xcode-compat/` directory is part of the ghostty and zmx fingerprints and of
the CI ghostty cache key, so editing a wrapper triggers a rebuild.

## Verification

- `zig build-exe hello.zig -lc` (zig 0.15.2, Xcode 26.6): without activation,
  `undefined symbol: _abort`; with activation it links and runs.
- libtool on the 14 cached ghostty archives: the stock tool kept 123 of 245
  members; the wrapper kept all 245, and all 11,533 exported symbols of the
  inputs are present in its output.
- The libtool probe flags the crafted unaligned archive (member dropped) and
  passes an `ar`-built aligned one (member kept).
- Cold build on Xcode 26.6 with empty `.build/ghostty` and `.build/zmx`
  (only the zig package cache kept) and no user-level workaround on PATH:
  `build-ghostty.sh` (4.5 min) and `build-zmx.sh` succeed, both probes fire,
  and `libghostty-fat.a` holds every exported symbol of its inputs.
  `make mac-build` then links the app and CLI, and the `Codans` test host
  launches. A second run hits the fingerprint in about 0.1 s without probing.

## Recurrence checks

- zig link errors listing basic libc symbols (`_abort`,
  `__availability_version_check`): run
  `grep -m1 '^targets:' "$(xcrun --sdk macosx --show-sdk-path)/usr/lib/libSystem.tbd"`.
- Undefined symbols from ghostty's C dependencies at the app link: search the
  zig build output for `not 8-byte aligned`, and compare
  `ar t libghostty-fat.a | wc -l` with the member count of its inputs.
- The build prints `xcode-compat: …` lines whenever a wrapper is active.
- When ghostty moves to a zig release that handles both issues, delete
  `scripts/xcode-compat/` and the `xcode_compat_*` calls.

## Pitfalls to remember

- **A warning can still mean lost output.** libtool exited 0 after dropping
  half the objects.
- **Probe for the condition; don't hardcode a machine.** The first
  workaround lived in `/tmp` and hardcoded `MacOSX15.4.sdk`.
- **PATH wrappers reach every child process.** Gate them on a variable that
  the parent sets, so tools that clear the environment get the real binary.
- **Don't try another zig inside the ghostty submodule.** Zig 0.16 creates
  `zig-pkg/` there. The fingerprint counts untracked files, so the leftover
  forces a full rebuild. Delete it and re-run `build-ghostty.sh` to settle
  the fingerprint again.
