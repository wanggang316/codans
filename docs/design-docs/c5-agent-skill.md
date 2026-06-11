# Design Doc: Published Agent Skill (C5)

> **Superseded by PR #15 (2026-04-21).** The `codans skill install / uninstall / status / bundle-path` subsystem, the `.app`-bundled skill, the mirror repo, and the Tier-A/B CI workflows described below have been removed. Skill under `skills/codans-cli/` is now pure text resource; engineering code does not reference, install, or version-sync with it. Users install the skill manually (`cp -r skills/codans-cli ~/.claude/skills/codans`) or via the agent's native skill installer. This document is retained for historical context only.

**Status:** Superseded
**Author:** Gump (with Claude)
**Date:** 2026-04-20
**Approved:** 2026-04-20 by Gump (autonomous resolution — see Decisions)

## Context and Scope

[Product spec C5](../product-spec.md) introduces a **Published Agent Skill** — a standard-format package (`SKILL.md` + `references/` + optional `agents/`) that teaches coding agents (Claude Code, Codex CLI, pi) how to drive codans via the `codans` CLI (C4) and the five-level hierarchy (C2). The skill is consumed by the agent, not by the app. It never runs inside the app process; the app has no loader, no plugin API, no runtime coupling.

The only runtime code on the app side is an **installation helper** — `codans skill install --claude-code | --codex | --pi` — that copies (or symlinks) the bundled skill into each agent's skill directory.

This document covers:

- Where the skill source lives in the repo and why.
- The package's internal shape (SKILL.md, references/, agents/<agent>/).
- The install CLI: surface, default paths, copy vs. symlink, error cases.
- How the skill stays in sync with `codans` (versioning and release).
- What SKILL.md teaches and, crucially, what it does **not** teach.
- Per-agent smoke tests so each release ships with evidence the skill works.

Repository state at the time of this design:

- `apps/mac/codans/main.swift` is a stub that prints the version. No `codans skill ...` subcommand exists yet.
- `codans-skill/` does **not** exist on disk. The [architecture § Future peer directories](../architecture.md) already reserves it as a planned peer of `apps/`.
- Per [architecture § Architectural Invariants](../architecture.md): "Agent Skill is consumed, never loaded. The app must not parse, index, or invoke `SKILL.md`." This design respects that invariant — there is no app-side code that reads skill content at runtime.

Downstream capabilities affected: none. C5 is deliberately orthogonal.

Product-spec Open Question #2 (skill repo location) is resolved here.

## Goals and Non-Goals

**Goals**

- Ship one skill package that three distinct agents (Claude Code, Codex CLI, pi) can consume without per-agent forks.
- Keep the skill's documented CLI surface in lockstep with the `codans` binary produced by the same build — no "installed skill claims flags the CLI no longer has."
- Give users a single command per agent (`codans skill install --<agent>`) that does the right thing on a clean machine and is idempotent on a dirty one.
- Make the skill upgradeable and inspectable: users can see what version is installed, uninstall cleanly, and reinstall after `codans` upgrades.
- Leave a credible path to a **mirror repo** (for users who want the skill without the app, e.g. `pi install git:github.com/…/codans-skill`) without changing the v1 shape.
- Provide per-agent smoke tests so every release can prove each agent can at least list and dispatch a trivial `codans` command from the skill.

**Non-Goals**

- Building a plugin / extension runtime in the app. The app still never loads `SKILL.md`.
- Authoring skills for agents beyond Claude Code, Codex CLI, and pi in v1.
- Shipping a separate skill-editor UI or in-app preview.
- Building pi-runtime extensions (`pi-notify-*`-style TypeScript code that reacts to agent events). That is a future product surface, not part of C5 v1.
- Schema-level validation / linting of third-party SKILL.md files. We only validate our own.
- Pinning the skill to a `codans` semver range tighter than major.minor — v1 ties skill version 1:1 to the `codans` release it ships with.

## Design

### Overview

The shape is three decisions locked together:

1. **Co-located source of truth.** The skill lives in `codans-skill/` as a peer of `apps/` in this monorepo. It is versioned with `codans`; a single git tag ships both. A separate **mirror repo** (`codans-skill`) is auto-published on release for users who want to consume the skill outside the app (e.g. via `pi install git:...`), but the mirror is a derived artefact — it has no independent life.

2. **One skill directory, per-agent wrappers.** The canonical content lives in `codans-skill/` at the package root: a single `SKILL.md` and a `references/` tree that every agent reads verbatim. Per-agent quirks (metadata files, agent-specific example recipes, hook-install notes) live under `codans-skill/agents/<agent>/`. The install CLI materialises the right shape at the right path per target agent.

3. **Copy by default; symlink as an opt-in for contributors.** `codans skill install` copies files into the agent's skill directory. Users get a self-contained copy immune to moves of the codans app bundle. Contributors pass `--link` to symlink for live iteration. A small `.codans-skill.json` sidecar records what was installed so `codans skill status` and `codans skill uninstall` work without guessing.

**Why this shape.** The central trade-off is source-of-truth vs. distribution. Keeping the skill in the app repo guarantees the documented flag set matches the binary on the same machine — the highest failure risk once we ship. A separate skills repo (option A2 below) looks cleaner but opens a correctness gap: a user who upgrades `codans` without upgrading the skill immediately reads stale docs. Co-location closes that gap by default and lets us publish the mirror as a *release artefact* rather than a *parallel codebase*. supaterm-skills (`supabitapp/supaterm-skills`) uses the separate-repo approach; we deliberately deviate on this one point because our release cadence is tied to the app and we want users to upgrade together.

### System Context Diagram

```
                               ┌──────────────────────────┐
                               │   codans (git repo)  │
                               │                          │
 apps/mac/codans  (binary) ◀──build─┤  apps/                   │
        │                      │  codans-skill/   ◀──  │  single source of truth
        │ `codans skill install`   │    SKILL.md               │  (this repo)
        ▼                      │    references/**          │
 ┌───────────────────┐          │    agents/                │
 │ Agent skill dir   │          │      claude-code/         │
 │  ~/.claude/skills/│ ◀copy/ln ┤      codex/               │
 │  ~/.codex/skills/ │          │      pi/                  │
 │  (pi: via mirror) │          │    package.json (pi)      │
 └───────────────────┘          └──────────────────────────┘
                                               │
                                   release CI  │  push subtree
                                               ▼
                               ┌──────────────────────────┐
                               │   codans-skill       │
                               │   (mirror, derived)      │   <── pi install git:...
                               └──────────────────────────┘
```

External boundaries:

- **Agent skill directories.** `~/.claude/skills/codans/` (Claude Code), `~/.codex/skills/codans/` (Codex CLI). These are user-owned, agent-defined paths; codans writes to them but never reads from them at runtime.
- **pi's git cache.** `~/.pi/agent/git/github.com/<org>/codans-skill/`. pi clones directly from a git URL; `codans skill install --pi` shells out to `pi install` rather than copying files into an arbitrary path.
- **Mirror repo.** A CI workflow on tagged releases pushes the `codans-skill/` subdirectory to a sibling GitHub repo. The mirror has no manual commits; it is re-generated from this repo on every release.

### Package Structure

```
codans-skill/
├── SKILL.md                     # Top-level teaching doc (see § SKILL.md template)
├── VERSION                      # Plain-text "0.1.0" — generated from codans's version on build
├── package.json                 # pi metadata (name, version, pi.skills entry)
├── references/
│   ├── hierarchy-model.md       # Space/Project/Worktree/Tab/Pane concepts (C2)
│   ├── targeting-and-selectors.md  # UUIDs, selectors, ambient env vars
│   ├── codans-cli.md                # Full `codans` subcommand reference for agents
│   ├── agent-hooks.md           # `codans agent install-hook`, lifecycle events (C3/C6)
│   ├── worktrees-and-editors.md # Worktree workflow + `codans open` (C2/C8)
│   └── recipes.md               # Copy-pasteable multi-step recipes
├── agents/
│   ├── claude-code/
│   │   ├── README.md            # "What Claude Code sees"; install path; troubleshooting
│   │   └── examples.md          # 3-5 example prompts that exercise the skill
│   ├── codex/
│   │   ├── README.md            # Same shape, Codex-specific notes
│   │   └── examples.md
│   └── pi/
│       ├── README.md            # pi install / discovery notes
│       └── examples.md
└── tests/
    ├── claude-code.smoke.md     # Scripted prompt + expected pass criteria
    ├── codex.smoke.md
    └── pi.smoke.sh              # Shell script; see § Testing strategy
```

**What goes where — the rule.** `SKILL.md` and `references/` are agent-agnostic. Everything that diverges per agent lives under `agents/<agent>/`. An install for a given agent materialises `SKILL.md` + `references/` + `agents/<agent>/` at the agent's skill path, under the directory name `codans/`.

**Why a top-level `VERSION` file.** Agents don't need it at read time, but `codans skill status` reads it to compare "bundled" vs. "installed" versions without parsing markdown frontmatter.

**Why a `package.json` at the package root.** pi's `install` command reads `package.json` to discover the skill. Claude Code and Codex ignore it, so there is no cost to its presence.

### API Design: `codans skill` CLI

Four subcommands. All are thin wrappers over filesystem operations — they do **not** read `SKILL.md` content beyond the version frontmatter.

```
codans skill install   --claude-code | --codex | --pi  [--dest <path>] [--link] [--force] [--dry-run]
codans skill uninstall --claude-code | --codex | --pi
codans skill status    [--json]
codans skill bundle-path          # prints the path to the bundled codans-skill/
```

**Default install paths** (sourced from `agents.json` — see § Data Storage):

| Agent | Destination |
|---|---|
| `--claude-code` | `~/.claude/skills/codans/` |
| `--codex` | `~/.codex/skills/codans/` |
| `--pi` | invokes `pi install git:<mirrorURL>`; default `mirrorURL` is `github.com/wanggang316/codans-skill`. No direct filesystem write. |

The claude-code and codex paths can be overridden with `--dest <path>` for users whose agent configs live elsewhere. pi has no `--dest` because pi owns its own git cache path; forks override the mirror URL by editing `agents.json` (or shipping a replacement resource).

**Flags:**

- `--link` — create a symlink to the bundle instead of copying. Requires the app stays installed at its current path; warn on removal. Intended for contributors editing the skill in-repo.
- `--force` — overwrite an existing `codans/` directory without prompting; otherwise install prompts once and aborts on "n".
- `--dry-run` — print what would be written, change nothing.

**Locating the bundle.** The app packages `codans-skill/` under `Resources/codans-skill/` in the `.app` bundle. `codans skill bundle-path` resolves it via `Bundle.main.resourceURL`; when `codans` is run outside a bundle (e.g. from `swift run` during dev), it walks up from the binary to find the repo root and uses `./codans-skill/`. The resolver lives in `apps/mac/codans/SkillBundleLocator.swift` (not `CodansCore` — it is host-environment code and would violate [architecture § Dependency Direction](../architecture.md)'s "`CodansCore` has zero internal deps and no environmental coupling" rule).

`codans skill status` reads every known agent's install marker (see § Data Storage) and prints a table:

```
Agent         Installed    Bundled    Mode     Path
claude-code   0.1.0        0.1.0      copy     ~/.claude/skills/codans
codex         -            0.1.0      -        -
pi            0.1.0 (pi)   0.1.0      git      ~/.pi/agent/git/github.com/.../codans-skill
```

The `pi` row reports whatever version pi's own cache reports for the mirror repo; the suffix `(pi)` flags that codans did not write this copy. `-` means "not installed." `--json` emits the same data structurally for scripting.

**Error cases and their responses:**

| Condition | Behaviour |
|---|---|
| Destination parent missing (`~/.claude/skills/` does not exist) | Create it (`mkdir -p`). Most users install the agent first, then codans; the parent exists. If not, creating it is harmless. |
| Destination `codans/` already exists, no marker | Prompt: "A `codans` directory exists at `<path>` but was not installed by `codans skill install`. Overwrite? [y/N]". `--force` skips the prompt. |
| Destination has a marker with the same version | No-op; print "already up to date". |
| Destination has a marker with a different version | Remove old directory, install fresh. Log the old version. |
| `--link` but the bundle lives inside a read-only signed `.app` | Warn once — the symlink still works but the app bundle may be replaced on upgrade, breaking the link. Recommend copy mode. |
| `--pi` but `pi` binary not on `$PATH` | Fail with exit code 2 and a message pointing to pi install docs. Never write anything. |
| `--pi` but network unavailable | `pi install` itself reports; `codans` forwards the exit code. |

### Data Storage

Two small JSON files. Neither is a skill-content artefact — the skill itself is markdown. These are machinery for the install CLI.

**1. `agents.json`** (read-only, shipped with the app at `apps/mac/Resources/agents.json`; bundled into `codans.app/Contents/Resources/agents.json`).

Source of truth for per-agent defaults — install path, pi mirror URL, optional per-OS overrides. Read at install time; never written.

```json
{
  "version": 1,
  "agents": {
    "claude-code": {
      "defaultPath": {
        "darwin": "~/.claude/skills/codans",
        "linux":  "~/.claude/skills/codans"
      },
      "installMode": "copy"
    },
    "codex": {
      "defaultPath": {
        "darwin": "~/.codex/skills/codans",
        "linux":  "~/.codex/skills/codans"
      },
      "installMode": "copy"
    },
    "pi": {
      "mirrorURL": "github.com/wanggang316/codans-skill",
      "installMode": "pi-install"
    }
  }
}
```

Readers abort on unknown top-level `version`, matching [architecture § Persistence](../architecture.md). Forks override by replacing the file in their fork's `Resources/`; no env-var or runtime override in v1 (keeps the install surface auditable).

**2. `.codans-skill.json`** (install marker, written into each destination by `codans skill install`).

```json
{
  "version": "0.1.0",
  "installedAt": "2026-04-20T10:00:00Z",
  "source": "copy",
  "bundlePath": "/Applications/codans.app/Contents/Resources/codans-skill",
  "bundleSha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}
```

`source ∈ {"copy", "symlink"}`. `bundleSha256` is the SHA-256 of a deterministic tarball of the bundled `codans-skill/` tree (sorted file list, file-mode + content concatenated). This is the hook for R3 (detecting user edits): on reinstall, `codans` rehashes the installed directory using the same algorithm and compares against `bundleSha256`; any drift prompts for overwrite unless `--force`. The check is cheap (< 10ms for the expected directory size) and bypassable.

**3. Marker read by the app (launch-time version banner).** The app does **not** parse skill content. It reads exactly one field — the top-level `version` string — from each agent's `.codans-skill.json`, using `JSONDecoder` against a minimal `InstalledSkillMarker` struct (`version: String` plus `CodingKey` whitelist). Equivalent to `jq '.version' <marker>`. If users prefer to avoid the direct read, the app may instead shell out to `codans skill status --json` and parse that output. Either path is acceptable; both stop at the version field and touch nothing else in the installed directory.

### Versioning and Release Process

The skill's version **equals the `codans` version on the same commit**, period. There is no independent skill semver. On a release build:

1. `apps/mac/scripts/generate-skill-version.sh` writes the current `codans` version into `codans-skill/VERSION` and into `codans-skill/package.json` (`version` field). Wired into `apps/mac/Makefile` as the `skill-version` target; the top-level `Makefile` forwards it (`make mac-skill-version`).
2. `make mac-skill-validate` runs the smoke-test harness (see § Testing strategy).
3. The signed `.app` bundles `codans-skill/` under `Contents/Resources/`.
4. A GitHub Actions workflow pushes `codans-skill/` to the mirror repo as a fresh commit tagged with the same version.

**Upgrade path for end users:**

- Claude Code / Codex: user runs `codans skill install --claude-code` (or `--codex`) after upgrading the app. This is a single command; idempotent; re-run cost is "rewrite ~30 small markdown files."
- pi: pi's own `pi update` refreshes from the mirror repo. Our docs point users to that flow.

**Upgrade detection (soft nudge).** On app launch, the app compares the bundled version (read from `codans-skill/VERSION` in the app's Resources) against each installed marker's `version` field — **one field only**, via the minimal decoder described in § Data Storage; no parsing of skill content. If a mismatch is found, surface a non-blocking in-app banner: "The skill installed for Claude Code is older than the bundled version. Run `codans skill install --claude-code` to upgrade." No auto-reinstall — user consent is required before we write into the agent's config tree.

**`codans` backward-compatibility guarantee for the skill.** Any change that removes or renames a `codans` subcommand documented in the current skill is a breaking change and bumps the major version. This gives the skill a hard contract to rely on.

### SKILL.md Template and Content Guidelines

SKILL.md follows the same shape as `skills/supaterm/SKILL.md`:

```markdown
---
name: codans
description: Control codans spaces, projects, worktrees, tabs, and panes with `codans`.
---

Use this skill when you need to control codans from a terminal that is
already running inside a codans Pane.

## Terminology
<Space / Project / Worktree / Tab / Pane, one line each>

## Fast Start
<5-8 commands covering `codans tree`, `codans worktree new`, `codans pane split`, `codans send`>

## Deep-Dive References
- [Targeting and selectors](references/targeting-and-selectors.md)
- [Hierarchy model](references/hierarchy-model.md)
- [`codans` CLI reference](references/codans-cli.md)
- [Agent hooks](references/agent-hooks.md)
- [Worktrees and external editors](references/worktrees-and-editors.md)
- [Recipes](references/recipes.md)
```

**Content rules:**

- **Teach the CLI surface, not the Swift types.** Agents cannot import Swift; they invoke `codans`. Every example is a shell command.
- **Prefer UUIDs in examples only when showing the full contract; prefer selectors (`1/2/3`) in Fast Start.** Selectors are short and readable for agents; UUIDs are accurate but visually noisy.
- **Show the ambient-context pattern.** The skill must explain that inside a Pane, most commands can omit the target because `CODANS_PANE_ID` is set (per [architecture § IPC](../architecture.md)).
- **Describe events and hooks at the CLI level, not the Swift level.** `codans agent install-hook claude` is the entry point — not `HookDispatcher.swift`.
- **Copy-pasteable recipes are the single most valuable section.** Every reference gets at least one worked example.
- **Tone: concise and imperative.** No marketing. No "Welcome to codans!" prose. Agents are the audience.

**Anti-content (things the skill must not include):**

- Swift code.
- Architecture diagrams (belong in `docs/architecture.md`).
- Rationale for design decisions (belong in `docs/design-docs/`).
- Claims about what agents "will" do; describe only what `codans` does.
- Screenshots.

**Anti-example (Swift-level reference that must not appear in the skill):**

> ~~To create a Pane, call `HierarchyClient.openPanel(tabID)` which dispatches through `TerminalEngine` → `GhosttyRuntime.ensureSurface(paneID)` and emits `.paneCreated` on the `AsyncStream<TerminalEvent>`.~~

Wrong on two counts: (1) it names Swift types the agent cannot invoke; (2) it leaks internals that may change without breaking `codans`'s CLI contract. The skill should instead say:

> To create a Pane, run `codans pane new` (creates in the current Tab) or `codans pane split <direction>` (creates by splitting). Both accept `--in <tab-or-pane>` for explicit targeting and print the new pane's ID with `--json`.

### Component Boundaries

```
codans-skill/                    (content-only; no Swift imports anywhere)

apps/mac/Resources/
└── agents.json                      (new) — per-agent default paths + pi mirror URL

apps/mac/codans/                         (Swift; the install CLI lives here)
├── main.swift                       (existing) — dispatch
├── SkillCommand.swift               (new) — `codans skill install|uninstall|status|bundle-path`
├── SkillInstaller.swift             (new) — pure file operations; unit-testable
├── SkillBundleLocator.swift         (new) — resolves bundle path (app vs. dev run)
└── AgentsConfig.swift               (new) — decodes agents.json; resolves per-OS paths

apps/mac/codans/App/
└── SkillVersionBanner.swift         (new) — reads bundled VERSION + installed marker.version
                                       ONLY; no SKILL.md parsing. Trivial one-liner; lives in
                                       the app target because it is UI state.

apps/mac/scripts/
└── generate-skill-version.sh        (new) — syncs codans version into VERSION + package.json
```

**Dependency rules (on top of [architecture § Dependency Direction](../architecture.md)):**

- `CodansCore` stays pure: no skill-related code lives there. Host-environment resolution (bundle paths, file-system scans, OS-specific defaults) belongs in the `codans` target.
- `codans-skill/` is not a Swift target, is not declared in `Project.swift`, and is not referenced from any Swift file except via the read-only `SkillBundleLocator` (which resolves a path, not file contents).
- `codans skill ...` runs entirely in `codans` — it does **not** need the app running. It is the only part of `codans` that bypasses IPC. This is acceptable because the operation is pure filesystem I/O with no relation to live app state.
- The app never calls `codans skill install` on behalf of the user. Install remains a deliberate user action.
- `SkillVersionBanner` in the app reads only the `version` field from `.codans-skill.json` (minimal `InstalledSkillMarker` struct) — it does **not** open `SKILL.md` or any other skill file.

**What each component is NOT responsible for:**

- `SkillInstaller`: does not parse SKILL.md or references; does not validate their content; it copies bytes.
- `SkillBundleLocator`: does not cache, does not fall back silently — errors are surfaced to the CLI caller.
- `AgentsConfig`: does not merge user-side overrides at runtime in v1; the shipped file is the full source of truth.
- `codans skill status`: does not probe pi's git cache contents for correctness; it only reports whether pi was invoked successfully last time and reads the version pi recorded for its cache entry.
- `SkillVersionBanner`: does not write; does not block launch; does not reinstall.

### Testing Strategy

Three layers. The lower two do not depend on the app or on `codans tree` being wired up, so C5 releases are not blocked by the rest of the product's completeness.

1. **Unit tests (CI, always run).**
   - `SkillBundleLocator` against a fake filesystem.
   - `SkillInstaller` round-trip: install → marker present → uninstall → directory gone; copy and symlink modes; error paths (pre-existing dir, read-only dest).
   - `AgentsConfig` decoding, OS selection, and unknown-version rejection.
   - Marker schema: `bundleSha256` computation is deterministic across sorted directory traversals.
2. **Tier-A smoke tests — skill-vs-CLI consistency (CI, always run, independent of app).**
   - **`codans-help-roundtrip`.** Parse every `codans <subcommand>` reference in `references/codans-cli.md` and assert each subcommand appears in `codans --help` (or a `codans help-json` dump). Catches doc drift without needing the app to be running. This is the primary release gate for the C5 content contract.
   - **Install-then-read.** `codans skill install --claude-code --dest <tmp>` then verify the directory tree against a golden manifest (file list + SHA-256s). No agent involvement.
3. **Tier-B per-agent live tests (manual + CI gate on release tag, once app/CLI are far enough along).**
   - **Claude Code (`tests/claude-code.smoke.md`).** A scripted session file that, when fed to a fresh Claude Code run inside a codans Pane, asks Claude to "List all panes and report the count." Passes if the returned count matches `codans tree --json | jq '.panes | length'`.
   - **Codex (`tests/codex.smoke.md`).** Same shape as Claude Code, adapted to Codex's invocation.
   - **pi (`tests/pi.smoke.sh`).** A shell script that runs `pi install git:...` against the mirror repo, then invokes pi non-interactively with a canned prompt and asserts the expected JSON output.

CI runs Tier-1 and Tier-A on every PR. Tier-B gates release tags; until `codans tree` (and the Pane IPC surface it needs) lands, a release can ship with Tier-A green alone — Tier-B then lights up incrementally as each agent's prerequisites arrive. This removes the ordering constraint between C5 and the rest of the capability graph.

## Alternatives Considered

### A1. Repo location: keep skill in the app repo subdirectory (**chosen**)

See Overview for rationale.

- **Pros:** single git tag ships skill + CLI together; no "stale skill vs. new CLI" gap; one CI to configure; contributors edit skill and CLI in one PR.
- **Cons:** the mirror repo is a derived artefact — we pay CI cost to maintain it; users who only want the skill have to pull via the mirror, not the canonical repo.

### A2. Repo location: separate `codans-skill` repo (supaterm-skills pattern) — rejected for v1

- **Pros:** clean distribution story (`pi install git:...`, `npx skills add`); independent release cadence; skill can be versioned on its own rhythm.
- **Cons:** correctness gap — users can easily upgrade `codans` without upgrading the skill and read stale flags. Two CI pipelines to keep green. Cross-repo PRs for contributors. The "independent release cadence" is actually a *liability* in v1 because the skill documents behaviours that only exist in specific `codans` versions.
- **Verdict:** rejected for v1. Revisit once the skill stabilises and we have a clear reason for independent versioning.

### A3. Per-agent forks: separate `codans-skill-claude`, `-codex`, `-pi` — rejected

- **Pros:** each agent gets tightly-tuned content.
- **Cons:** triple the maintenance for content that is 95% identical. Drift between forks is inevitable. Adding a new `codans` subcommand means three docs to update.
- **Verdict:** rejected. Put shared content at the root and per-agent quirks under `agents/<agent>/`.

### A4. Install mechanism: app writes directly at first launch — rejected

- **Pros:** zero-touch UX; the skill is just "there" after install.
- **Cons:** violates the "install remains a deliberate user action" principle — writing into `~/.claude/` without consent is invasive; users who don't use Claude Code shouldn't have files appear there. Upgrades become ambiguous (do we overwrite an edited file?). Fails the agents' own expectations (Claude Code users expect to opt skills in, not receive them).
- **Verdict:** rejected. `codans skill install` is a single explicit command.

### A5. Install mechanism: shell script only, no `codans` subcommand — rejected

- **Pros:** simpler to implement; no CLI plumbing.
- **Cons:** users have to know the shell script exists, find it in the `.app` bundle, and invoke it with the right args. Discoverability is worse than `codans skill install`. Idempotence/status become opaque.
- **Verdict:** rejected. `codans skill` is worth the ~200 lines of Swift.

### A6. Default to symlink instead of copy — rejected

- **Pros:** upgrades are "automatic" after `codans` upgrade; no reinstall needed.
- **Cons:** the symlink points into the `.app` bundle. On macOS, upgrading the app may replace the bundle (some update paths re-create it with a different inode, others rewrite in place), so a symlink *may* break on upgrade depending on how the user installed the new version. Uninstalling the app always breaks the symlink. Copy is more predictable and matches how agents treat skill directories (user-owned).
- **Verdict:** rejected as default; kept as an opt-in `--link` flag for contributors.

### A7. One SKILL.md per agent in the same directory — rejected

- **Pros:** each agent reads its own file; no wrapper step in install.
- **Cons:** loses the single source of truth; duplicates terminology and Fast Start. Drift is inevitable. Agents' own skill loaders expect exactly one `SKILL.md`.
- **Verdict:** rejected. Share the root; specialise under `agents/<agent>/`.

## Cross-Cutting Concerns

### Security

- `codans skill install` writes only under `~/.claude/`, `~/.codex/`, or (for pi) wherever pi places its git cache. No system paths. No sudo. No PATH modifications.
- Copy mode pulls bytes from the signed `.app` bundle; no network activity. `--pi` shells out to the user's `pi` binary, which itself performs a git clone over HTTPS.
- The install marker stores a timestamp and a resolved bundle path. Bundle paths can leak user HOME info into `.codans-skill.json`, which lives in the user's HOME; this is acceptable.
- `codans skill install --dest <path>` validates that `<path>` is under the user's HOME. Writing outside HOME is refused. This is a defence-in-depth check: the agents' own conventions already put their skill dirs under HOME.

### Observability

- `os.Logger` category `com.gumpw.codans.skill` logs install / uninstall / status with the resolved paths and exit status.
- `codans skill install --dry-run` prints every file that would be copied. Useful for support diagnostics.

### Upgrade and migration

- v1 skill is version 0.1.0 (aligned with `codans` 0.1.0). On `codans` minor/patch upgrades the skill is regenerated mechanically; users re-run `codans skill install`.
- A deprecated-field policy for the install marker (`.codans-skill.json`): readers tolerate unknown fields but reject unknown top-level `version`. Same rule as [architecture § Persistence](../architecture.md).
- If a future `codans` version needs the skill to be at a specific minimum version to function, `codans` prints a warning pointing at `codans skill install` on startup.

### Rollback

- `codans skill uninstall --<agent>` removes the installed `codans/` directory, nothing else. Agents degrade to "skill not available" — no further codans-specific knowledge, but the agent itself keeps working. Reinstall restores.
- Rollback of an app version does not require a skill rollback — the agent just continues using whatever is installed until the user runs install again.

### Orthogonality (architectural invariant)

- The app bundle contains `codans-skill/` as static resources. No Swift code under `codans/` (the app target) imports it. Enforced by code review and by the fact that `codans-skill/` has no `module.modulemap` and is not referenced in `Project.swift`.
- `codans skill ...` is the single bridge and it is strictly a file-copy tool.

### Testing (per-agent)

Covered above in § Testing Strategy. Smoke tests are the release-gate contract that proves each agent can actually exercise the skill.

## Decisions (locked at approval)

Numbered for easy cross-reference. Revisit via amendment.

1. **Repo location: subdirectory of this repo for v1.** `codans-skill/` is a peer of `apps/`. Resolves product-spec Open Question #2. A mirror repo is published by release CI for out-of-app distribution.
2. **Directory name at install target is `codans/`.** Every agent's skills dir gets `codans/` as the subdirectory containing `SKILL.md`. Matches the supaterm convention (`~/.claude/skills/supaterm/`).
3. **Copy by default; `--link` opt-in.** Users get a self-contained copy. Contributors can symlink.
4. **Skill version == `codans` version.** No independent semver. A single git tag ships both.
5. **No auto-install on first app launch.** Install is always explicit. A non-blocking in-app banner nudges the user when the installed version is older than the bundled version.
6. **pi install via the mirror repo.** `codans skill install --pi` shells out to `pi install git:github.com/<owner>/codans-skill`. Direct filesystem install into pi's cache is not supported.
7. **Smoke tests gate tagged releases.** Unit tests run on every PR; per-agent smoke tests block release-tag CI.
8. **SKILL.md teaches the CLI, not the internals.** Explicit content rule — no Swift, no architecture diagrams, no rationale prose in the skill.
9. **Mirror repo is generated, not authored.** CI pushes `codans-skill/` to the mirror on tag. Manual commits to the mirror are forbidden (enforced by branch protection in that repo).
10. **`codans skill` is the only app-bundled command that bypasses IPC.** All other `codans` subcommands require the app to be running; `codans skill ...` does not, because it operates on user files.
11. **`agents.json` is the single source of truth for per-agent paths and the pi mirror URL.** It ships read-only in `apps/mac/Resources/agents.json`, is decoded at install time, and is rebuildable from the design (see § Data Storage). Forks override by replacing the file; no runtime env-var override in v1.
12. **Pi mirror URL default: `github.com/wanggang316/codans-skill`.** This is a placeholder for the canonical upstream owner; swapping it is a one-line edit in `agents.json`. Forks ship their own value.
13. **`SkillBundleLocator` lives in `apps/mac/codans/`, not `CodansCore`.** Bundle-path resolution is host-environment code. Keeping it out of `CodansCore` preserves [architecture § Dependency Direction](../architecture.md)'s "Core has zero environmental coupling" rule.

## Risks

- **R1 — Mirror repo drift.** A human with write access to the mirror pushes a manual commit that then diverges from this repo. Mitigation: branch protection on the mirror repo (only the release bot can push); release CI asserts the subtree diff is empty before tagging.
- **R2 — Agents change their skill directory convention.** Claude Code / Codex / pi may relocate `~/.claude/skills/` to a new path in a future release. Mitigation: `codans skill install` reads a small `agents.json` shipped in `apps/mac/Resources/` that maps agent → default path; updating the map is a minor release.
- **R3 — Users edit the installed skill.** A user tweaks `~/.claude/skills/codans/SKILL.md` and then runs `codans skill install --claude-code`, losing their edits. Mitigation: the marker's `bundleSha256` field (see § Data Storage) records the hash of the tree at install time. On reinstall, `codans` rehashes the installed directory and compares; any drift prompts "Overwrite local edits? [y/N]" unless `--force`.
- **R4 — `--link` mode silently breaks after app upgrade.** Symlink resolves through a now-deleted bundle path. Mitigation: `codans skill status` detects broken symlinks and reports them; install warns at link time about this failure mode.
- **R5 — pi binary not installed; user confused by `--pi` failure.** Mitigation: exit code 2 plus an explicit pointer to pi install docs, and a check in `codans skill status` that reports "pi not found" instead of silent absence.
- **R6 — Skill contents claim a `codans` flag that was renamed.** The skill is markdown; nothing statically catches this. Mitigation: a `make skill-verify` step (release-gated) parses `references/codans-cli.md` for `codans <subcommand>` occurrences and diffs against `codans --help-json` output. Unknown flags fail the build.
- **R7 — Mirror repo consumers pin an old commit and get stuck on a broken version.** Mitigation: the mirror tags every release identically to the app; users pin a tag, not a commit. Documented in the mirror's README (which is itself generated).
- **R8 — Users want to install the skill without installing the app.** Mitigation: the mirror repo is exactly this path. We document it in `codans-skill/agents/pi/README.md` and on the project README.

## Open Items

- **O1 — pi extension story.** supaterm-skills ships a `pi-notify-supaterm` extension (TypeScript, runtime reactor). codans may want a peer `pi-notify-codans`. This is **out of scope for C5 v1**. If built, it lives in a future peer directory (e.g. `codans-extensions/`) and has its own design doc.
- **O2 — Windows / Linux install paths.** v1 is macOS-only per product-spec, but pi users may run on Linux. `agents.json` already supports per-OS overrides; concrete paths are added when those platforms become in-scope.

*(The previous O1 — mirror repo name and owner — is resolved by Decision 12.)*
