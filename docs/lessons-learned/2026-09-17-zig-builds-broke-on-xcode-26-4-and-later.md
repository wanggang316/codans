# Lessons Learned: zig 0.15.2 builds broke on Xcode 26.4 and later

**Status:** Resolved
**Date:** 2026-09-17
**Area:** Build toolchain (`build-ghostty.sh`, `build-zmx.sh`, `apps/mac/scripts/xcode-compat/`, ghostty fork `v1.3.1-tc`)
**Fix:** branch `build/xcode26-zig-compat` (PR #192); ghostty fork commit `be9f1562f2` (backport of ghostty-org/ghostty#11999)

## Summary

On a Mac with Xcode 26.6, a cold `make mac-build` failed twice, at two
different stages, while CI (pinned to Xcode 26.0) stayed green:

1. Every zig link in the ghostty and zmx builds failed with undefined libc
   symbols.
2. Once that was worked around, ghostty's inner `xcodebuild` could not link
   `libghostty-fat.a`: symbols from ghostty's C dependencies (`imgui_draw`,
   oniguruma encodings, …) were undefined.

Upgrading zig was not an option. The ghostty fork is based on v1.3.1, whose
`build.zig` accepts only zig 0.15.2. Upstream moved to zig 0.16.0 later
(ghostty-org/ghostty#12726), more than 2,600 commits past v1.3.1.

## Root cause

1. **The SDK's libSystem stubs are arm64e-only (Xcode 26.4+).** The macOS SDK
   in Xcode 26.4 and later declares only arm64e for Apple silicon in
   `usr/lib/libSystem.tbd`:
   `targets: [ x86_64-macos, x86_64-maccatalyst, arm64e-macos, arm64e-maccatalyst ]`.
   Apple's `ld` accepts arm64e stubs when it links arm64. Zig 0.15.2's linker
   requires an exact `arm64-macos` match, so it finds no usable libSystem and
   reports every libc symbol as undefined. Even a minimal program fails:

   ```
   $ zig build-exe hello.zig -lc
   error: undefined symbol: _abort
   ```

   The zig issue is ziglang/zig#31658. It was fixed by ziglang/zig#31673,
   which shipped only in zig 0.16.0; there is no 0.15.3. Ghostty's own report
   (ghostty-org/ghostty#11991) was closed without a build-side fix, because
   the build runner itself fails to link before `build.zig` can run a check.
   Zig finds the SDK only through `xcrun --sdk macosx --show-sdk-path`
   (`std/zig/system/darwin.zig`). The Command Line Tools on the same machine
   still ship `MacOSX15.4.sdk`, whose stubs list `arm64-macos`.

2. **libtool drops unaligned archive members.** Ghostty merges its static
   libraries with `libtool -static -o libghostty-fat.a <libs…>`
   (`src/build/LibtoolStep.zig`). Zig 0.15.2's archiver does not pad members
   to 8-byte offsets. Recent Apple libtool (seen here in Xcode 26.6,
   `cctools_ld-1267`; upstream hit it in March 2026) skips such members with
   only a warning:

   ```
   libtool: warning: 64-bit mach-o member 'zutil.o' not 8-byte aligned
   ```

   libtool still exits 0, so the zig build reports success. Re-running the
   merge on the 14 archives in ghostty's zig cache kept 123 of 245 objects.
   The missing objects only showed up later, as undefined symbols at the app
   link.

## Fix

- **libtool: upstream backport in the ghostty fork.** ghostty-org/ghostty#11999
  (upstream `a83a82b3f8`, not in any 1.3.x tag) is cherry-picked onto
  `v1.3.1-tc`. Before the merge, `LibtoolStep` copies each input archive and
  runs `ranlib` on the copy, which rewrites it with aligned members. The step
  lives inside zig's build graph, so its inputs, and therefore its cache key,
  change with the fix. A `libghostty-fat.a` truncated by an earlier build is
  not reused.
- **SDK: `apps/mac/scripts/xcode-compat/`.**
  - Both zig build scripts source `activate.sh`. It runs just before
    `zig build`, and only when the build fingerprint misses.
  - If the resolved SDK's `libSystem.tbd` has no `<arch>-macos` target,
    `activate.sh` picks the newest installed SDK that has one (Xcode's
    platform directory first, then the Command Line Tools). It exports that
    SDK as `CODANS_ZIG_MACOS_SDK` and prepends `bin/` to PATH.
  - `bin/xcrun` answers exactly zig's query with that SDK and forwards
    everything else to `/usr/bin/xcrun`.
  - If no installed SDK qualifies, the build stops with an explanation.
  - The wrapper does nothing unless the variable is set. Ghostty's inner
    `xcodebuild` inherits PATH but no other environment variables
    (`GhosttyXcodebuild.zig`), so it keeps the stock SDK and linker.
  - Switching SDKs needs no cache handling for ghostty: `pkg/apple-sdk`
    writes the SDK paths into a content-addressed `libc.txt` and
    `-F` / `-I` arguments, and those are part of every compile step's
    arguments.

On Xcode 26.0 (CI) the SDK check passes and nothing is redirected. The
`xcode-compat/` directory is part of the ghostty and zmx fingerprints and of
the CI ghostty cache key.

### Rejected: flattening archives in a PATH `libtool` wrapper

The first version of PR #192 put a `libtool` wrapper on PATH. The wrapper
extracted each input with `ar x` before merging, which kept all 245 objects.
It was dropped for three reasons:

- `ar x` is not semantics-preserving: duplicate member names collide, and
  member order can change. The wrapper had to refuse such archives.
- Zig's Run step cache keys on a step's arguments and input files, not on
  PATH or the environment (`std/Build/Step/Run.zig`). Turning the wrapper on
  therefore re-used an archive the stock libtool had already truncated. The
  fix needed its own cache-invalidation layer and a regression test.
- Upstream had already fixed the problem inside the build graph, where
  neither issue exists.

## Verification

- `zig build-exe hello.zig -lc` (zig 0.15.2, Xcode 26.6): without the SDK
  redirect, `undefined symbol: _abort`; with it, the program links and runs.
- Merging the 14 cached ghostty archives with libtool:
  - stock: 123 of 245 members kept;
  - after `cp` + `ranlib`, with or without `-D`: all 245 members kept, no
    warnings, all 11,533 global symbols of the inputs present, member names
    and order unchanged.
  - Plain `ranlib` output is not byte-identical across runs; `ranlib -D`
    output is. Zig caches the step's output, so this does not matter here.
- Migration on Xcode 26.6:
  1. From an empty local zig cache, the unpatched fork with only the SDK
     redirect: libtool printed 10 `not 8-byte aligned` warnings and cached a
     `libghostty-fat.a` with 118 members, and ghostty's inner `xcodebuild`
     failed at `Ld`.
  2. With the backport, on that same cache: `build-ghostty.sh` succeeded
     (about 5 min) and wrote a new `libghostty-fat.a` with 230 members, with
     no alignment warnings. The truncated archive stayed in the cache
     unused.
  3. `build-zmx.sh` and the `Codans` / `codans-cli` builds succeeded.
  4. A second `build-ghostty.sh` run hit the fingerprint in about 0.1 s.

## Recurrence checks

- **zig link errors on basic libc symbols** (`_abort`,
  `__availability_version_check`): run
  `grep -m1 '^targets:' "$(xcrun --sdk macosx --show-sdk-path)/usr/lib/libSystem.tbd"`.
- **Undefined symbols from ghostty's C dependencies at the app link:**
  - search the zig build output for `not 8-byte aligned`;
  - compare `ar t libghostty-fat.a | wc -l` with the member count of its
    inputs;
  - check that the fork still carries the `ranlib` normalization in
    `src/build/LibtoolStep.zig`.
- **Redirect active:** the build prints an `xcode-compat: …` line whenever
  the SDK redirect is on.
- **Upgrading the fork base:** once the fork is based on an upstream release
  that includes #11999, drop the backport. Once it is on zig ≥ 0.16 (and zmx
  is too), delete `scripts/xcode-compat/` and the `xcode_compat_*` calls.

## Pitfalls to remember

- **A warning can still mean lost output.** libtool exited 0 after dropping
  half the objects.
- **Check upstream before building a workaround.** The libtool fix already
  existed upstream as a small build-graph change; the local wrapper cost a
  review round and a cache-invalidation layer.
- **Zig's build cache does not see the toolchain.** A Run step that calls a
  tool by name is cached on its arguments and inputs only. Fix tool behaviour
  inside the build graph, or invalidate the cache explicitly. A build that
  starts from an empty cache cannot catch this.
- **Probe for the condition; don't hardcode a machine.** The first
  workaround lived in `/tmp` and hardcoded `MacOSX15.4.sdk`.
- **PATH wrappers reach every child process.** Gate them on a variable that
  the parent sets, so tools that clear the environment get the real binary.
- **Don't try another zig inside the ghostty submodule.** Zig 0.16 creates
  `zig-pkg/` there. The fingerprint counts untracked files, so the leftover
  forces a full rebuild. Delete it and re-run `build-ghostty.sh` to settle
  the fingerprint again.
