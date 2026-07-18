---
name: crash-resolve
description: Triage and resolve a codans crash reported to Sentry. Pull the symbolicated stack from the Sentry API, map the in-app frame to source, fix the root cause, and drive the issue's status (resolve / resolve-in-next-release / archive) with an audit trail. Use when the user references a Sentry crash, a SIGABRT / EXC_BAD_ACCESS / SIGSEGV / NSException report, a dashboard issue id like APPLE-MACOS-4, release health, or asks to triage / fix / resolve crashes.
---

# crash-resolve: resolve a codans crash from Sentry

## Overview

codans reports uncaught crashes (Mach exceptions, POSIX signals,
`NSException`) and Swift errors to **Sentry** on release builds, with
stacks symbolicated against the dSYMs uploaded per release. This skill is
the end-to-end loop for turning one of those reports into a verified fix:

> **operate Sentry** (read the event) → **localize & fix** the root cause →
> **manage the issue's status** (resolve in the next release, with a note).

Crash reporting is **opt-in** and PII-minimised, so volume is low and
every real crash is signal — there is no noise budget to hide behind.
Background on the pipeline lives in
[`docs/references/crash-reporting.md`](../../../docs/references/crash-reporting.md)
and [ExecPlan 0017](../../../docs/exec-plans/0017-crash-reporting.md).

## When to use

- The user points at a Sentry issue (`APPLE-MACOS-N`), a crash signature
  (`SIGABRT`, `EXC_BAD_ACCESS`, `SIGSEGV`, `NSException`), or asks to
  triage / fix / resolve crashes.
- A release went out and you want to check release health / new crashes.

**Don't use** for:
- Wiring up the SDK, DSN, or dSYM upload — that's the setup checklist in
  `docs/references/crash-reporting.md`, not this skill.
- Non-crash product bugs with no Sentry report.

## Project facts (load before acting)

| Concern | Value |
|---|---|
| Sentry org slug | `thinking-function` |
| Sentry project slug | `apple-macos` (id `4511455005310976`) |
| Dashboard | `https://thinking-function.sentry.io/issues/` |
| Auth token | `~/.sentryclirc` `[auth] token=`, or `$SENTRY_AUTH_TOKEN` |
| Release name | `codans@<MARKETING_VERSION>` (e.g. `codans@0.4.13`) |
| `dist` | build number `YYYYMMDDNNN` |
| Telemetry source | `apps/mac/codans/App/Telemetry/` |
| Noise filter | `Telemetry/SystemHangFilter.swift` (`systemNoiseSignatures`) |
| Helper | `.claude/skills/crash-resolve/scripts/sentry.sh` |

There is **no `sentry-cli` installed and no Sentry MCP** — the REST API
(via the helper below) is the operating surface.

---

## 1. Operating Sentry (操作方法)

Use the bundled helper; it resolves the token + org/project, accepts the
friendly `APPLE-MACOS-N` short ids, and fails loud on non-2xx. From the
repo root:

```bash
S=.claude/skills/crash-resolve/scripts/sentry.sh

$S list                                    # unresolved, by frequency
$S list "is:unresolved error.unhandled:true"   # crashes only (NOT is:unhandled)
$S show   APPLE-MACOS-4                     # status, counts, first/last seen, assignee
$S event  APPLE-MACOS-4                     # latest event: exception + symbolicated stack
$S event  APPLE-MACOS-4 oldest             # the first occurrence (regression range)
```

`event` prints the exception, the `release`/`dist`, key tags (os, device,
handled, mechanism, user), and the stacktrace with `[APP]` marking
in-app frames — those filenames + line numbers (e.g.
`CommandRunner.swift:132`) point straight at codans source.

Mutating commands (need an `event:write`-scoped token):

```bash
$S resolve-next APPLE-MACOS-4              # resolved in the NEXT release (default for a code fix)
$S resolve      APPLE-MACOS-4              # resolved now (no release binding)
$S archive      APPLE-MACOS-4              # archive / ignore (out of the queue)
$S unresolve    APPLE-MACOS-4              # reopen
$S assign       APPLE-MACOS-4 user:<id>   # or team:<id> | <email>
$S comment      APPLE-MACOS-4 "fixed in <commit/PR>; root cause: ..."
```

**Auth & scopes.** Reads need `event:read`; mutations need `event:write`.
A `403` means the token lacks a scope — mint one at Sentry → Settings →
Auth Tokens. The DSN/dSYM token in CI (`project:*`, `releases`) is a
*different* token and is not for issue management.

**Mutations hit the team's live Sentry.** Run `resolve*` / `archive` /
`assign` only as part of an actual resolution the user wants — they
change shared state and show up in the issue's activity log.

**Raw API fallback** (everything is under `https://sentry.io/api/0`, org
`thinking-function`):

| Need | Method + path |
|---|---|
| List | `GET /projects/{org}/{project}/issues/?query=…&statsPeriod=14d` |
| Detail | `GET /organizations/{org}/issues/{shortId}/` |
| Latest event | `GET /organizations/{org}/issues/{shortId}/events/latest/` |
| Update status / assignee | `PUT /organizations/{org}/issues/{shortId}/` |
| Add note | `POST /organizations/{org}/issues/{shortId}/comments/` |

`statsPeriod` only accepts `''`, `24h`, or `14d`. For longer windows use
`start`/`end` ISO timestamps.

---

## 2. Status management conventions (状态管理规范)

Sentry states and what they mean here:

| State | Set via | Use when |
|---|---|---|
| **unresolved** (`new` → `ongoing` → `escalating`/`regressed`) | default / `unresolve` | Not yet fixed, or reopened. |
| **resolved in next release** | `resolve-next` | **Default for any crash you fixed in code.** Ties the fix to a release. |
| **resolved** | `resolve` | The cause was infra/transient/external (no codans build will "contain" the fix). |
| **archived / ignored** | `archive` | System noise, not-a-bug, or won't-fix. Never for a real crash you simply haven't fixed. |

**Why resolve-in-next-release is the default.** Releases and dSYMs are
keyed by `codans@<version>`. Resolving *in the next release* lets Sentry
**auto-reopen the issue as `regressed`** if the same crash recurs in a
build ≥ the fixing release — i.e. it catches a bad fix instead of
silently masking it. Plain `resolve` loses that guard.

**System noise.** If an event's frames are *entirely* macOS/AppKit
internals (`mach_msg`, `__CFRunLoopRun`, `CGS*`, WindowServer round-trips)
it is a miss by `SystemHangFilter`. Add the offending frame substring to
`SystemHangFilter.systemNoiseSignatures` **and** `archive` the issue —
don't `resolve` it (there is no code bug to fix), and the new signature
re-ships so future copies are dropped before they reach the dashboard.

**Insufficient data.** A single old event with no in-app frame and no
repro: don't `resolve` without a fix. Leave it unresolved, or `archive`
(it surfaces again if it escalates). Note what's missing in a comment.

**Handled errors ≠ crashes.** `error.unhandled:false` items (e.g.
`HTTPClientError 504`) are network/server-side; `archive` or adjust the
client, don't treat them as a crash fix.

**Always leave a trail.** On every resolution `comment` the issue with
the fixing commit/PR and a one-line root cause, and `assign` if you're
handing off. A bare status flip with no note is not done.

---

## 3. Resolution workflow (解决流程)

0. **Pick a target.** `$S list "is:unresolved error.unhandled:true"`.
   Prioritise by event count, user count, and recency.

1. **Read the event.** `$S event <shortId>`. Capture: exception type,
   `release`/`dist`, os/device, and the `[APP]` frame(s).

2. **Noise check.** If *every* frame is system-level → it's a
   `SystemHangFilter` miss: add the signature + `archive`, then stop
   (see status rules). Otherwise continue.

3. **Localize.** Open the `[APP]` frame's `file:line`, read the
   surrounding code, and form 1–3 root-cause hypotheses ranked by
   likelihood. Common codans crash classes: Swift concurrency / actor
   isolation, view/observable lifecycle (synthesized **isolated deinit**
   — prefer an explicit `deinit`), force-unwraps, and subprocess plumbing
   (always via the shared `CommandRunner`, never a raw `Process`).

4. **Corroborate.** If repro is feasible, reproduce. Otherwise reason
   from the stack + tags; compare `event … oldest` vs `latest` to see
   whether release/device narrows the cause.

5. **Fix the root cause** and add a guard or test that would have caught
   it. Match surrounding conventions; keep the change surgical.

6. **Verify locally.** Build + the relevant tests (`make mac-build`,
   targeted test target) and confirm the crash path is gone. "Looks
   right" is not verification — cite the command and result.

7. **Commit** referencing the issue (e.g. `fix(...): … (APPLE-MACOS-4)`).
   The fix ships in the *next* release.

8. **Update Sentry.** `$S resolve-next <shortId>` and `$S comment
   <shortId> "<commit/PR> — root cause: …"`. Assign if handing off.

9. **Close the loop on release.** After the fix release is cut (the
   `release` skill) and its dSYMs upload, the issue is verified. If the
   same crash reappears in a build ≥ the fixing release, Sentry reopens
   it as `regressed` — re-triage from step 1.

## Pitfalls

- Resolving a crash **before** the fix ships, then forgetting the next
  build never contained it — use `resolve-next`, not `resolve`.
- `is:unhandled` is **not** a valid query token; use
  `error.unhandled:true`.
- Editing the generated Xcode project, or spawning `Process` directly in
  a fix — both violate codebase conventions; see `CLAUDE.md`.
- Treating a `SystemHangFilter` miss as a code bug. Archive + extend the
  signature list instead.
