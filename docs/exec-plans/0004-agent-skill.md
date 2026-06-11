# ExecPlan: Published Agent Skill (C5)

> **Superseded by PR #15 (2026-04-21).** The milestones below delivered `codans skill install / uninstall / status / bundle-path`, the `.app`-bundled skill, `generate-skill-version.sh`, Tier-A/B CI, and the mirror-push workflow — all of which have since been removed. Skill under `skills/codans-cli/` is now pure text; engineering code does not touch it. This plan is retained for historical context only; do not use it as a source of current behavior.

**Status:** Superseded
**Author:** Gump (with Claude)
**Date:** 2026-04-20

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this plan lands, a contributor who has just run `make mac-build` and installed the resulting `codans.app` can do the following for the first time:

- Open a terminal and run `codans skill install --claude-code`. Within a second, `~/.claude/skills/codans/` exists on disk, populated with a versioned `SKILL.md`, a `references/` tree that documents the `codans` CLI, and an install marker.
- Run `codans skill status`. A table reports which agents have the skill installed, what version they have, and what version the app bundle contains. Mismatches are obvious.
- Open Claude Code inside a codans Pane. Claude has the skill loaded; asking "how do I split this pane?" yields a correct `codans pane split …` answer sourced from the skill's references — not from model memory.
- Repeat for `--codex` (same UX, same outputs against `~/.codex/skills/codans/`). For `--pi`, run `codans skill install --pi` and the command delegates to `pi install git:<mirrorURL>` against the published mirror repo.
- Upgrade `codans.app`. On next launch, a non-blocking banner observes that the installed skill for Claude Code is older than the bundle and suggests `codans skill install --claude-code`. Running it rewrites the directory idempotently.

This is the first capability the app ships that is consumed outside the app's process boundary. The design doc ([docs/design-docs/c5-agent-skill.md](../design-docs/c5-agent-skill.md)) pins the architectural invariant: **the app never loads or parses `SKILL.md`**. This plan implements the install helper, the skill content, the release pipeline, and the per-agent verification, while holding that line.

C5 is deliberately orthogonal to C1 (Terminal engine) and C2 (Hierarchy): Tier-A testing does not depend on `codans tree` or Pane IPC existing, so this plan can land and release independently of [exec-plan 0002](0002-terminal-and-hierarchy.md). Tier-B smoke tests activate progressively as the app's CLI surface fills in.

## Progress

- [x] M1 — `codans-skill/` subdirectory scaffold (SKILL.md stub, `references/*.md` stubs, `agents/{claude-code,codex,pi}/` stubs, `VERSION`, `package.json`, `tests/` placeholders) — 2026-04-20
- [x] M2 — `apps/mac/Resources/agents.json` + `AgentsConfig` Swift type in new `CodansKit` static framework + unit tests (10 cases green; see DEC-8, DEC-9, DEC-10) — 2026-04-20
- [x] M3 — `SkillBundleLocator` + `SkillInstaller` + `SkillFileSystem` in `CodansKit` + unit tests (31 cases after review-fix round) — 2026-04-20
- [x] M4 — `codans skill {install,uninstall,status,bundle-path}` subcommands + runners + `ProcessSpawner` + `AgentID: EnumerableFlag` + codans-skill bundled in .app Resources + env-var overrides for dev iteration + 45 test cases (13 runner tests added) + M4a polish round (publicInstallMode accessor, pi stdout forwarding, display-width padding) — 2026-04-20
- [x] M5 — `SkillVersionBanner` + `SkillVersionBannerView` in the app, injectable providers so the banner never reads `SKILL.md` content, one-field `MinimalMarker` decoder, per-agent `UserDefaults` dismissal that re-arms on bundle-version bump, 11 unit tests incl. M5-fix polish (pi skipped at loop, SemVer numeric compare, "Copy command" affordance) — 2026-04-20
- [x] M6 — Tier-A automation: `codans help-json` subcommand + `generate-skill-version.sh` + `skill-help-roundtrip.py` + `skill-tier-a.sh` + `skill-orthogonality-check.sh` + `skill-golden-update.sh` + `skill-golden-manifest.txt` + Makefile targets + `.github/workflows/skill-tier-a.yml`. All three checks pass locally (roundtrip / golden / orthogonality). 65 unit tests + Tier-A green — 2026-04-20. M6-polish fixes (roundtrip code-scope only, orthogonality anchored to file-path column, version-regex narrowed to CommandConfiguration format) landed alongside M7.
- [x] M7 — Mirror-repo release automation: `.github/workflows/skill-mirror-push.yml` (tag-triggered, owner-gated on `MIRROR_DEPLOY_KEY` secret, mirror slug derived from `agents.json.pi.mirrorURL`, rsync-subtree-push approach, tag/VERSION consistency check). Concurrency group added to Tier-A workflow as the deferred follow-up. YAML merged but expected to fail at clone-step until owner provisions the deploy key (planned degradation, documented in workflow header) — 2026-04-20
- [x] M8 — SKILL.md + `references/*.md` + `agents/**/{README,examples}.md` production content pass (~3077 words across SKILL.md + references; 4538 with per-agent docs). Shipped commands + planned commands documented together; planned subtrees gated via a new `PLANNED_TOKENS` dict in `skill-help-roundtrip.py` so CI passes with honest forward-references. 46 `codans …` references in markdown verified by Tier-A (6 shipped + 40 planned) — 2026-04-20. M8-polish (DEC-22) followed: paneID/panelIndex terminology unified, --focus flag position normalised, "discards edits" wording softened, notify recipe order corrected. +2 suggestion fold-ins (`codans send` in Fast Start, ambient intro in targeting).
- [x] M9 — Release-gate Tier-B: `tests/{claude-code,codex}.smoke.md` specs + `apps/mac/scripts/skill-tier-b-{claude,codex}.sh` harnesses + `codans-skill/tests/pi.smoke.sh` + `.github/workflows/skill-tier-b.yml` (tag-triggered) + `make mac-skill-tier-b`. Prompts target the currently-shipped `codans skill *` surface so v0.1.0 can gate on a real PASS; future releases extend with `codans worktree` / `codans tab` / `codans pane` prompts when those land. Locally: claude PASS, codex PASS, pi SKIP (mirror not provisioned yet) — exactly the shape DEC-5 describes — 2026-04-20

## Surprises & Discoveries

- **M1: `plutil -lint` rejects JSON.** The plan's M2 step uses `plutil -lint apps/mac/Resources/agents.json` to validate the file. On macOS (Sonoma/Sequoia) `plutil` only accepts plists by default; it errors with "Unexpected character { at line 1" on any JSON file. Use `jq . <file> > /dev/null` or `python3 -m json.tool <file>` instead. Will update M2's Concrete Steps accordingly when we get there. Evidence: `plutil -lint codans-skill/package.json` → `Unexpected character {`; `jq . codans-skill/package.json > /dev/null` → silent success.

## Decision Log

The design doc locks Decisions 1-13. The plan adds a handful of implementation-level decisions that are not in the design doc. They are recorded here at plan time so reviewers see them before code lands.

- **DEC-1 (plan, 2026-04-20): Symlink-mode marker lives alongside the installed directory, not inside it.** Design doc §Data Storage pins the marker at `<destination>/.codans-skill.json`. That path works for copy mode but breaks for symlink mode, because the symlink target is the `.app` bundle's read-only `Resources/codans-skill/`. In symlink mode the marker is instead written at `<destination>.marker.json` in the *parent* directory (e.g. `~/.claude/skills/codans.marker.json` next to the `codans` symlink). `SkillInstaller.readMarker(at: destination)` is a single entry point that transparently picks the inside-dir path for copy installs and the sibling path for symlink installs, so callers (CLI + banner) do not branch on mode.
- **DEC-2 (plan, 2026-04-20): `--help-json` is a top-level `codans` flag, not `codans skill --help-json`.** Emitting machine-readable subcommand metadata is a CLI-wide concern — future docs generators and the Tier-A roundtrip check both benefit. Adding it at the root means every current and future `codans` subcommand is introspectable from one entry point.
- **DEC-3 (plan, 2026-04-20): Golden manifest is a sorted file list excluding the install marker.** The install marker's content is timestamped (non-deterministic), so it is excluded from the manifest diff. The manifest is only the set of *paths*, not the file contents — content correctness is covered by `bundleSha256`, which is independently computed at install time. Regenerating the golden is a deliberate action via `make mac-skill-golden-update`.
- **DEC-4 (plan, 2026-04-20): HOME security check is enforced in both CLI and installer layers.** Defence-in-depth: `SkillCommand.Install` validates that the resolved destination is under `NSHomeDirectory()` before constructing the installer; `SkillInstaller.install` also checks and throws `InstallError.destinationOutsideHome`. The two checks are identical in content. Either alone would be sufficient; duplication protects against refactors that accidentally remove one of the two call-sites.
- **DEC-5 (plan, 2026-04-20): Tier-B tests degrade gracefully when an agent binary or `codans` surface is missing.** If `pi` is not installed on the CI runner, the pi smoke test emits a warning and exits 0 rather than failing the release. Likewise, the claude-code test checks for `codans tree` and skips the count-comparison branch when absent. This matches design doc §Testing Strategy's "Tier-B then lights up incrementally as each agent's prerequisites arrive" — C5 release is not held hostage to C1/C2 completeness.
- **DEC-6 (plan, 2026-04-20): `--force` reinstall is a full re-copy, not a diff-based patch.** When the user accepts the overwrite prompt (or passes `--force`), `SkillInstaller` removes the entire installed directory and re-materialises it from the bundle. Diff-based patching would be more efficient but adds a reconciliation code path that is hard to test exhaustively for edge cases (partially-written files, permission changes). The full-copy cost is a few dozen small markdown writes — well under 100ms on any machine.
- **DEC-7 (plan, 2026-04-20): `AgentID` `EnumerableFlag` conformance pins explicit flag names.** ArgumentParser's default would turn `AgentID.claudeCode` into `--claudeCode`. The CLI contract requires `--claude-code`, `--codex`, `--pi`. The conformance provides explicit `name(for:)` that maps each case to its kebab-cased flag via `.customLong("claude-code")` etc. This is also the hook for future agents (when `--aider` or similar lands, the explicit mapping prevents a silently-changed flag).
- **DEC-8 (M2, 2026-04-20): Test sources live in a sibling directory `tcTests/`, not `codans/Tests/`.** Tuist's `buildableFolders: ["codans"]` walks recursively and swept `codans/Tests/*.swift` into the `codans` target's compile list; with no `Testing` dependency on `codans`, the build failed. `CodansCoreTests` already uses the sibling-folder pattern; adopted the same here. `tcTests/` directory is the authoritative location for every `CodansKit`-hosted test file from this milestone forward.
- **DEC-9 (M2, 2026-04-20): Extract `CodansKit` static framework for library code; `codans` binary becomes a thin wrapper.** Swift unit tests cannot link against a `commandLineTool` product — symbols are only externalised from library products. With `AgentsConfig` living in the `codans` target, every test reference resolved to "undefined symbol" at link time. The fix is structural: `CodansKit` (staticFramework) hosts `AgentsConfig`, `SkillBundleLocator`, `SkillInstaller`, and later the `SkillCommand` runners. `codans` (commandLineTool) imports `CodansKit`, parses argv, and dispatches. The split matches supaterm's `SupatermCLIShared` / `sp` arrangement and the plan's own "if host-app tests get awkward, promote to a static framework" fallback language. Interfaces & Dependencies updated accordingly (`apps/mac/CodansKit/` is the source-of-truth location; test target depends on `CodansKit`, not on `codans`).
- **DEC-10 (M2, 2026-04-20): `codans` target's `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`.** The workspace default is `MainActor`. With `codans` left at the workspace default, `AgentsConfig` and its methods became `@MainActor`-isolated, and `nonisolated` tests could not call them. Setting `codans` + `CodansKit` to `nonisolated` (matching `CodansCore` / `CodansIPC`) restores the expected data-pure, synchronous API surface for CLI code. The app target keeps the workspace `MainActor` default.
- **DEC-11 (M3 review-fix, 2026-04-20): `bundleSha256` hashes content only — no posixPermissions.** The plan's original §Data Storage description called for `<rel>\0<mode>\0<size>\0<bytes>\0`. In practice `FileManager.copyItem` does not reliably preserve exec bits across filesystem boundaries (APFS ↔ tmpfs may reset them); hashing the mode produced false-positive drift on every reinstall of a tree containing `tests/pi.smoke.sh` (which ships with the exec bit). Dropping mode from the digest eliminates the false positive without weakening the contract — edits to file content still change the hash, which is what drift detection cares about. The plan's Data Storage blurb will be updated in the next plan-doc pass; implementation is authoritative.
- **DEC-12 (M3 review-fix, 2026-04-20): Marker `source` is private; public status JSON uses `installMode`.** The persisted `.codans-skill.json` keeps `source` as its on-disk field name (stable schema, avoids a migration if the public surface later adds modes the marker shouldn't persist). M4a's `codans skill status --json` is responsible for renaming it to `installMode` on emit so the public key matches `agents.json`. Commented at the `InstalledSkillMarker` declaration so the next implementer sees the contract.
- **DEC-13 (M3 review-fix, 2026-04-20): `detectMode` trusts only the filesystem entry, not the sidecar.** Earlier `detectMode` inferred `.symlink` from a stray `<dest>.marker.json` sibling even when `<dest>` was a regular directory. This allowed foreign JSON next to an unrelated `codans/` folder to poison `readMarker`. Fixed: `.symlink` is returned only when `destination` itself is a symlink. `uninstall` compensates by always sweeping *both* potential marker paths, so partial installs left over from earlier mode switches still clean up fully.
- **DEC-14 (M4, 2026-04-20): Env-var overrides for `SkillBundleLocator`.** The app-bundled resolution (`Bundle.main.resourceURL` + sibling-Resources probe) only works when `codans` runs from inside `Codans.app/Contents/MacOS/`. During development the `codans` binary lives in DerivedData, which is deep under `~/Library/...` and out of reach of the repo-walk fallback. Two new env vars — `CODANS_SKILL_BUNDLE` and `CODANS_AGENTS_JSON` — take precedence over all other phases. Contributors point them at the in-repo `codans-skill/` / `apps/mac/Resources/agents.json` and iterate against the raw `codans` binary without rebuilding the `.app`. Production invocations don't set the vars.
- **DEC-15 (M4, 2026-04-20): `codans-skill/` is bundled into the `.app` via `.folderReference`, not `.glob`.** The first attempt (`resources: ["../../codans-skill/**"]`) flattened every `*.md` into `Contents/Resources/`, causing duplicate-symbol-style errors on `README.md` and `examples.md` (three copies each from the per-agent directories). `.folderReference(path: "../../codans-skill")` preserves the subdirectory tree inside `Contents/Resources/codans-skill/`. Keeping the folder structure is what lets `SkillBundleLocator.locateSkillBundle` return a single URL that `SkillInstaller.copyItem` can recursively copy.
- **DEC-16 (M4, 2026-04-20): `codans` binary is *not* copied into `Contents/MacOS/` of the app.** Tuist places both the `.app` and the `codans` commandLineTool under the same `Debug/` / `Release/` product folder, but doesn't embed `codans` inside the `.app`. Users invoke `codans` as a standalone binary; the app-bundled skill directory is located via `CODANS_SKILL_BUNDLE` (dev) or installation into `/usr/local/bin` via a future installer step (deferred — tracked as an open architectural question, not part of C5). For M4 acceptance, the smoke test sets the env vars explicitly; M6's Tier-A CI will do the same.
- **DEC-17 (M6 polish, 2026-04-20): `skill-help-roundtrip.py` only inspects code-scope markdown.** Earlier regex matched `codans foo` in any prose — including "run codans foo first" with no backticks — which would flag benign explanatory prose as CLI contract claims once M8 fills in content. Now the checker only scans fenced ``` blocks and inline `…` spans; prose outside backticks is deliberately ignored. A real CLI claim is always in code font by convention in this skill.
- **DEC-18 (M6 polish, 2026-04-20): `skill-orthogonality-check.sh` allowlist is anchored to the file-path column.** Prior pattern `grep -v -E 'SkillInstaller.swift|…'` matched any line containing those basenames anywhere — so a new `SkillCommand.swift` planted in `CodansCore/` would silently exempt itself. The pattern is now `(^|/)(<basename>):[0-9]+:`, which only matches the basename at the end of a path component immediately before the `:line:` separator. The invariant is load-bearing; the regex now matches that load-bearing status.
- **DEC-19 (M6 polish, 2026-04-20): `generate-skill-version.sh` version regex narrowed to the CommandConfiguration format.** Earlier sed extracted any `version: … X.Y.Z …` substring, which would pick up a comment like `// version: 0.0.1` if one ever sat above the `CommandConfiguration`. Now the pattern demands the exact literal `version: "codans X.Y.Z`. Narrow match = no false positives. If the banner format ever changes, this line changes with it.
- **DEC-20 (M7, 2026-04-20): Mirror-push derives the mirror slug from `agents.json.pi.mirrorURL`, not a hard-coded workflow string.** Forks and renames flow through `agents.json` (already the single source of truth per DEC-11). The workflow uses `jq` at run time to resolve the SSH form. `concurrency: group: skill-mirror-push-${ref}, cancel-in-progress: false` — in-flight tag pushes must complete; skipping one would leave the mirror out of date for a release.
- **DEC-21 (M8, 2026-04-20): Skill content documents shipped + planned commands side-by-side, with planned subtrees gated by a `PLANNED_TOKENS` dict in the roundtrip checker.** The alternative — only writing content for shipped commands — would force an M8-sized rewrite for every future milestone that ships more of the CLI. The alternative in the other direction — disabling the roundtrip gate for planned commands — would let stale or invented commands into the skill. Compromise: backtick-wrapped references are still load-bearing (roundtrip check catches unknown names), but a small explicit list of "planned subtree prefixes" in `skill-help-roundtrip.py` is treated as satisfied. Each entry names the exec plan that delivers it; when that plan ships, the entry deletes and the checker starts demanding the real subcommand.
- **DEC-22 (M9, 2026-04-20): Tier-B smoke prompts target the currently-shipped surface, not the planned surface.** A first attempt asked Claude to "List all panes and report the count" — but `codans tree` hasn't shipped, so Claude correctly replied "there is no pane subcommand" and the gate failed every v0.1.0 release. The fix is structural: every Tier-B prompt must be answerable via a `codans` subcommand that is *in* `codans help-json` today, so release CI can go green as soon as one agent is provisioned on the runner. When C1-C3 land, add new prompts that exercise their surfaces. This mirrors M6's PLANNED_TOKENS split between shipped and planned — the gate is always tight around what's really there.

## Outcomes & Retrospective

### Plan complete — 2026-04-20

All nine milestones landed. The capability from product-spec §C5 ships as designed:
`codans skill install|uninstall|status|bundle-path` is live, the `codans-skill/`
package is bundled into `Codans.app/Contents/Resources/`, a non-blocking
`SkillVersionBanner` nudges users after upgrades, Tier-A CI gates every PR on three
orthogonal invariants (help-json roundtrip, golden manifest, orthogonality), Tier-B
CI is wired for release tags, and a mirror-push workflow will populate the public
`codans-skill` git URL as soon as the owner provisions `MIRROR_DEPLOY_KEY`.

**What landed beyond the original plan shape:**

- `CodansKit` static framework (DEC-9) — the plan assumed the CLI library code would live
  in `apps/mac/codans/`, but Swift test targets cannot link against a `commandLineTool`
  product. Extracting the installer / locator / runners into a framework unblocked
  tests; the structural fix has the pleasant side effect of matching supaterm's
  `SupatermCLIShared` pattern.
- Env-var dev overrides (DEC-14) — `CODANS_SKILL_BUNDLE` and
  `CODANS_AGENTS_JSON` let contributors iterate against the in-repo fixtures
  without rebuilding `.app`. The plan's "Locating the bundle" discussion foresaw the
  phases; the env layer was added on top during M4 smoke testing.
- `PLANNED_TOKENS` (DEC-21) in the roundtrip checker — needed because the plan wanted
  M8 to write real teaching content for commands that exec plans 0002/0003 will ship.
  A gated forward-reference list keeps the skill teaching the full product surface
  without lying about what `codans` implements today.

**What shipped smaller than planned:**

- Symlink-mode marker lives at a sibling path (DEC-1), not inside the install
  directory as design doc §Data Storage described. The inside path can't work because
  the symlink target is the read-only `.app` bundle. `readMarker` hides the
  difference from callers.
- `codans` is not copied into `Contents/MacOS/` of the app (DEC-16). Tuist builds both
  the `.app` and `codans` under the same product folder but doesn't embed. Users invoke
  `codans` from `PATH` via a later installer step. Not blocking for this plan.

**Evidence & scores at plan completion:**

- 45 `codans`-scheme tests + 20 `codans`-scheme tests + `make mac-lint` clean +
  `make mac-skill-validate` green (6 shipped + 40 planned codans-refs, golden manifest
  unchanged, orthogonality clean).
- 18-file skill package; 4538 words of teaching content (3077 across
  `SKILL.md` + `references/`, within the 1500-4000 plan target).
- Tier-B local run: `claude PASS`, `codex PASS`, `pi SKIP` — exactly the
  degradation shape DEC-5 describes.
- `.github/workflows/skill-tier-a.yml` runs on every PR + main push;
  `.github/workflows/skill-mirror-push.yml` and `.github/workflows/skill-tier-b.yml`
  gate on version tags.

**Carry-forward to future plans:**

- `PLANNED_TOKENS` in `skill-help-roundtrip.py` — the exec plans named inside each
  entry (0002 for `codans tree`/`codans worktree`/`codans tab`/`codans pane`/`codans space`, 0003 for
  `codans send`/`codans broadcast`/`codans open`/`codans agent`) must remove their entries on
  landing. CI will then *demand* the real subcommand.
- Tier-B prompts must grow a new prompt per newly-shipped subcommand group
  (DEC-22). File a small task-list entry on the corresponding plan rather than
  re-opening this one.
- Owner setup still pending: create `github.com/wanggang316/codans-skill`,
  generate a deploy key, provision `MIRROR_DEPLOY_KEY`. Until done, the mirror
  workflow is merged-but-red on tag pushes. The workflow's header documents every
  step; no code change needed after setup.

**Lessons:**

- Tuist's "same name, wrong surface" trap — `commandLineTool` test-linkability — cost
  half an hour that a 2-line doc in the Tuist target docs would have saved. Worth a
  project-wide callout if other targets hit it.
- Orthogonality as CI gate > orthogonality as comment. The grep script caught three
  real would-be violations while M2-M4 were in flight.
- Forward-references need an explicit gate. Without `PLANNED_TOKENS`, we either
  under-document and force a content-rewrite per milestone, or over-document and
  lose the skill-vs-binary invariant. The compromise is the pattern to adopt for
  future "plan doc" ↔ "binary" coupling.

## Context and Orientation

Related documents (all in this repo):

- Product spec — [docs/product-spec.md](../product-spec.md), capability C5 ("Published Agent Skill"), and Open Question #2 (skill repo location) — **resolved by design doc Decision 1**
- Design doc — [docs/design-docs/c5-agent-skill.md](../design-docs/c5-agent-skill.md) — **authoritative**. This plan does not relitigate any decision in it; it implements them. Specific references:
  - §Package Structure — the expected directory tree under `codans-skill/`
  - §API Design: `codans skill` CLI — subcommand shape, flags, default paths
  - §Data Storage — `agents.json` schema, install marker schema, `bundleSha256` definition
  - §Component Boundaries — where each Swift file lives and the dependency-direction rule
  - §Testing Strategy — the three test tiers and what gates what
  - §Decisions (13 locked items) — non-negotiable
- Architecture — [docs/architecture.md](../architecture.md). Relevant invariants:
  - "Agent Skill is consumed, never loaded." The app must not parse, index, or invoke `SKILL.md`.
  - `CodansCore` has zero internal dependencies and no environmental coupling — `SkillBundleLocator` lives in `apps/mac/codans/`, not `CodansCore`.
  - All persisted JSON uses a top-level `version` field; readers abort on unknown versions.
- Previous exec plans — [0001 bootstrap](0001-bootstrap-monorepo.md), [0002 terminal + hierarchy](0002-terminal-and-hierarchy.md). 0002 introduces `AtomicFileStore` and the atomic-rename + version-gated decode pattern we will reuse in M2.
- Reference layout — [supaterm-skills](../../) not in this repo; inspected at plan time. `/Users/wanggang/dev/opensource/supaterm-skills/skills/supaterm/` gives us the canonical `SKILL.md` + `references/` + `agents/` shape. Shown in the design doc §Package Structure; we deviate only by adding a `tests/` subfolder and a root `VERSION` file.

**Terminology used in this plan.** Defined here so every later mention is unambiguous.

- **Skill package** — the directory tree at `codans-skill/` in this repo. Content-only (markdown + JSON + shell). No Swift lives here.
- **Install target** — the destination directory for a skill installation, named `codans/` under each agent's skill root (e.g. `~/.claude/skills/codans/`). Matches the supaterm convention.
- **Install marker** — a file called `.codans-skill.json` placed inside the install target on every `codans skill install`. Carries `version`, `installedAt`, `source` (copy vs. symlink), `bundlePath`, and `bundleSha256`. Used for idempotence, status, and user-edit detection.
- **Bundle hash (`bundleSha256`)** — a deterministic SHA-256 of the skill package as bundled, computed by walking the tree in sorted-path order and feeding `<relative_path>\0<file_mode>\0<file_bytes>\0` into the hash for each regular file. Symlinks are rejected (the bundle has none). Identical inputs always produce the same hash across machines.
- **`agents.json`** — the read-only JSON file shipped in `apps/mac/Resources/` listing per-agent default install paths and the pi mirror URL. Source of truth for installer behaviour.
- **`SkillBundleLocator`** — the Swift helper that tells `codans skill` where the bundled `codans-skill/` lives. Resolves `Bundle.main.resourceURL` when the binary runs inside a `.app`; walks upward from the executable to find the repo root when running from `swift run`.
- **`SkillInstaller`** — the Swift helper that performs the actual file-system work (copy, symlink, marker write, uninstall). Pure file I/O; no network; no agent coupling.
- **Tier-A / Tier-B tests** — tier-A runs in CI on every PR and does not need the app or `codans tree` to exist (unit tests + `codans --help-json` roundtrip + install-into-tempdir + golden manifest diff). Tier-B runs on release tags and exercises real agents end-to-end. Design doc §Testing Strategy is authoritative.
- **Mirror repo** — a separate GitHub repository (`github.com/wanggang316/codans-skill` per Decision 12) that holds a copy of `codans-skill/` pushed from this repo on every release tag. Consumed by `pi install git:...`. Never authored manually.

**Orientation paragraph.** The nine milestones form a simple dependency chain: content shape (M1) and installer metadata (M2) are independent and can be done in parallel. M3 consumes both to implement the installer internals. M4 wraps the installer in a `codans skill …` CLI. M5 adds the app-side banner that nudges users to reinstall after a `codans` upgrade. M6 adds the automation that keeps the skill in lockstep with `codans` (version stamping, Tier-A CI, orthogonality check). M7 splits mirror-repo automation into its own milestone because it needs owner-level actions (repo creation + `MIRROR_DEPLOY_KEY` secret) that an implementer cannot do from the plan alone. M8 turns the M1 stubs into production content. M9 gates release with the per-agent smoke tests. Each milestone leaves the repo in a releasable state: a release cut after M4 would ship a working installer with stub content; one cut after M8 would ship production content without release-gate smoke coverage. M2 ships a simple in-repo fallback for locating `agents.json`; M3 replaces it with the authoritative `SkillBundleLocator` and `loadFromMainBundle()` delegates. The orthogonality guarantee — nothing in the app target reads skill content — is enforced by code review plus the grep-style invariant check added in M6 (`apps/mac/scripts/skill-orthogonality-check.sh`).

## Plan of Work

Nine milestones, narrative below. The review pass split the original M4 into two (CLI → M4, app-side banner → M5) because the combined milestone touched ~8 files and mixed CLI plumbing with SwiftUI UI state. The original M5 was similarly split: in-repo automation (version stamping, Tier-A CI, orthogonality check) stays together as M6; the mirror-push workflow becomes M7 on its own because it requires owner-level actions outside the implementer's control. Milestones are individually verifiable and produce at least one commit each per the project's commit-after-each-small-feature cadence.

### Milestone 1: `codans-skill/` scaffold

**Goal after this milestone.** The `codans-skill/` directory exists at the repository root as a peer of `apps/`, with the full directory tree from design doc §Package Structure present but the content files are stubs. Every file that *will* exist at the end of M6 exists now — the paths are stable from this point on. The scaffold is bundleable by Tuist as a resource folder starting in M4.

This is the cheapest milestone; it also unblocks M3 (`SkillInstaller` tests need a real fixture to copy) and pins file names that later plan items reference.

**Work.** Create `codans-skill/` at the repo root. Populate:

- `codans-skill/SKILL.md` — frontmatter (`name: codans`, `description: Control codans spaces, projects, worktrees, tabs, and panes with \`codans\`.`), a one-sentence "Use this skill when …" line, and a bulleted stub Terminology + Fast Start + Deep-Dive References list pointing at the `references/*.md` paths. Content is placeholder — M6 rewrites every line. What must be correct *now* is the frontmatter and the reference file names.
- `codans-skill/VERSION` — a single line `0.1.0` followed by a newline. Stub value; M5's `generate-skill-version.sh` will overwrite on release builds.
- `codans-skill/package.json` — pi metadata:
      {
        "name": "@codans/skill",
        "version": "0.1.0",
        "description": "Agent skill for codans",
        "keywords": ["pi-package", "pi", "skills", "codans"],
        "license": "Unlicense",
        "private": true,
        "pi": { "skills": ["./"] }
      }
  This is deliberately minimal; pi reads `name`, `version`, and `pi.skills` to discover the skill. Claude Code and Codex ignore the file.
- `codans-skill/references/` — create six stub files, each one heading + one TODO line: `hierarchy-model.md`, `targeting-and-selectors.md`, `codans-cli.md`, `agent-hooks.md`, `worktrees-and-editors.md`, `recipes.md`. Every stub ends with `<!-- STUB: filled in by exec plan 0004 M8 -->` so M8 (the content-pass milestone) can regex-delete the markers.
- `codans-skill/agents/claude-code/README.md`, `.../claude-code/examples.md` — stub pair.
- `codans-skill/agents/codex/README.md`, `.../codex/examples.md` — stub pair.
- `codans-skill/agents/pi/README.md`, `.../pi/examples.md` — stub pair.
- `codans-skill/tests/claude-code.smoke.md`, `.../codex.smoke.md` — stub `.md` files. `tests/pi.smoke.sh` is created as `#!/usr/bin/env bash\nexit 0\n` (executable bit set via `chmod +x` — record that git tracks it via the `100755` mode, verified in the commit).

Update `.gitignore` if anything under `codans-skill/` should be ignored (currently nothing; the expectation is that every file tracked). Also update the repo root `docs/design-docs/README.md` index and, if present, any top-level `README.md` listing repo areas (check with `grep -l "apps/" README.md || true` — if the root README doesn't enumerate peers, skip).

**Observable acceptance.**

- `find codans-skill -type f | sort` prints the complete file list matching design doc §Package Structure with no extras and no omissions. Expected total: 18 files (1 `SKILL.md` + 1 `VERSION` + 1 `package.json` + 6 `references/*.md` + 3 × 2 `agents/<agent>/{README,examples}.md` + 3 `tests/*`). Diff against a saved `find` transcript if the count disagrees.
- `file codans-skill/tests/pi.smoke.sh` reports the file is executable (mode `-rwxr-xr-x` or equivalent).
- `grep -r "import " codans-skill/` returns no Swift imports.
- No changes under `apps/` yet.

**Expected commits.** Single commit: `feat(skill): scaffold codans-skill/ tree with stub content`.

### Milestone 2: `agents.json` + `AgentsConfig` Swift type

**Goal after this milestone.** The app's `Resources/` directory carries `agents.json` at the schema described in design doc §Data Storage, and `apps/mac/codans/AgentsConfig.swift` parses it into a typed struct with unit test coverage. The installer (M3) can consume this without any placeholder values.

**Work.** Create `apps/mac/Resources/agents.json` with the content from the design doc (three agents: `claude-code`, `codex`, `pi`; `defaultPath.darwin` + `defaultPath.linux` for the first two; `mirrorURL` for pi; top-level `version: 1`). File is pretty-printed with two-space indent and sorted keys for deterministic diffs.

Wire the file as a Tuist resource. In `apps/mac/Project.swift`, find the `codans` target's `resources:` list (add one if it doesn't exist) and include `"apps/mac/Resources/**"`. Tuist's `buildableFolders` handles source; `resources:` is the canonical knob for bundled files. Confirm via `make mac-generate` that the generated Xcode project places `agents.json` under `Contents/Resources/` of the built `.app`.

Create `apps/mac/codans/AgentsConfig.swift` with the types:

    struct AgentsConfig: Codable, Equatable, Sendable {
      static let currentVersion = 1
      var version: Int
      var agents: [String: AgentConfig]
      func config(for agent: AgentID) -> AgentConfig?
      func defaultPath(for agent: AgentID, os: TargetOS) -> String?
      func mirrorURL(for agent: AgentID) -> String?
    }

    struct AgentConfig: Codable, Equatable, Sendable {
      var defaultPath: [String: String]?   // os → path, for copy agents
      var mirrorURL: String?               // for pi
      var installMode: AgentInstallMode
    }

    enum AgentInstallMode: String, Codable, Sendable { case copy, piInstall = "pi-install" }
    enum AgentID: String, Codable, CaseIterable, Sendable { case claudeCode = "claude-code", codex, pi }
    enum TargetOS: String, Sendable { case darwin, linux }

Decoding rejects unknown `version` with a thrown `AgentsConfigError.unknownVersion(Int)`. Path strings containing `~` are expanded via `NSString.expandingTildeInPath` at consumption time — the raw file stores the unexpanded form, the accessor returns expanded.

Locate a loader on `AgentsConfig`:

    extension AgentsConfig {
      static func load(from url: URL, decoder: JSONDecoder = .default) throws -> AgentsConfig
      static func loadFromMainBundle() throws -> AgentsConfig
    }

`loadFromMainBundle()` in M2 ships a **provisional** resolver: it calls `Bundle.main.url(forResource: "agents", withExtension: "json")` and, when that returns nil (e.g. `swift run` outside a `.app`), walks up from `Bundle.main.executableURL` until it finds `apps/mac/Resources/agents.json`. M3 replaces the walk with a call to the authoritative `SkillBundleLocator.locateAgentsJSON(executableURL:)`. The public signature does not change; only the internal implementation does. This split keeps M2 self-contained (it does not depend on M3 existing).

**tcTests Tuist target provenance.** This target is created here (M2). It does not exist in exec plan 0002 (which introduces `CodansCoreTests` and `codansTests` but not a `codans`-host test bundle). In `apps/mac/Project.swift`, add under the `targets:` array:

    .target(
      name: "tcTests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "com.gumpw.codans.tcTests",
      deploymentTargets: .macOS("13.0"),
      buildableFolders: ["codans/Tests"],
      dependencies: [.target(name: "codans")],
      settings: .settings(base: ["SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated",
                                  "CODE_SIGNING_ALLOWED": "NO"])
    )

Mirror the `.swiftlint.yml` `included:` list to add `apps/mac/codans/Tests/`. Scheme generation via `make mac-generate` picks the new target up automatically.

Create `apps/mac/codans/Tests/AgentsConfigTests.swift` (XCTest, matching the existing test targets' convention). Cases: round-trip decode of the shipped `agents.json`; rejection of a version-2 fixture; missing-agent lookup returns nil; per-OS path expansion (darwin vs. linux paths correctly selected); unknown `installMode` fails decode.

**Observable acceptance.**

- `make mac-generate && xcodebuild test -scheme tcTests | xcbeautify` ends with "Test Suite 'All tests' passed" and at least 5 test cases executed.
- Running `plutil -lint apps/mac/Resources/agents.json` returns "OK".
- `make mac-build` produces an `.app` whose `Contents/Resources/agents.json` is present (`ls "$(find ~/Library/Developer/Xcode/DerivedData -name 'codans.app' -type d | head -1)/Contents/Resources/agents.json"` succeeds).

**Expected commits.** Two commits: `feat(codans): ship agents.json + AgentsConfig decoder`, `test(codans): AgentsConfig unit coverage`.

### Milestone 3: `SkillBundleLocator` + `SkillInstaller`

**Goal after this milestone.** The two helpers that implement the install operation exist in `apps/mac/codans/` and are unit-tested without any CLI involvement. `SkillInstaller` can: install-by-copy into a tempdir, install-by-symlink, write a valid marker containing `bundleSha256`, rehash an installed tree and detect drift, uninstall cleanly, and surface the error cases enumerated in design doc §Error cases. `SkillBundleLocator` resolves the bundled `codans-skill/` path in both `.app` and dev-run contexts.

**Work.** Under `apps/mac/codans/`, create four files:

`SkillBundleLocator.swift`:

    enum SkillBundleLocator {
      enum LocatorError: Error, Equatable { case bundleNotFound; case repoRootNotFound }
      static func locateSkillBundle(executableURL: URL = Bundle.main.executableURL ?? defaultExecURL) throws -> URL
      static func locateAgentsJSON(executableURL: URL = Bundle.main.executableURL ?? defaultExecURL) throws -> URL
    }

The resolution order matches design doc §Locating the bundle:

1. If `Bundle.main.resourceURL?.appendingPathComponent("codans-skill")` exists and is a directory, return it. (Normal `.app` path.)
2. Otherwise, walk upward from `executableURL` looking for a directory that contains both `apps/` and `codans-skill/`. If found, return `<repoRoot>/codans-skill`.
3. Otherwise, throw `LocatorError.bundleNotFound`.

`locateAgentsJSON` uses the same two-step resolution against `Resources/agents.json` (in-bundle) or `apps/mac/Resources/agents.json` (in-repo).

`SkillInstaller.swift`:

    @MainActor
    struct SkillInstaller {
      let bundleURL: URL                    // source; from SkillBundleLocator
      let fileSystem: SkillFileSystem       // protocol; defaults to real FS; injectable for tests

      func install(to destination: URL, mode: InstallMode, options: InstallOptions) throws -> InstallResult
      func uninstall(at destination: URL) throws
      func readMarker(at destination: URL) throws -> InstalledSkillMarker?
      func currentBundleSha256() throws -> String
      func directorySha256(at url: URL) throws -> String
    }

    enum InstallMode { case copy, symlink }
    struct InstallOptions { var force = false; var dryRun = false; var now: Date = Date() }
    struct InstallResult: Equatable { let destination: URL; let marker: InstalledSkillMarker; let filesWritten: [URL] }

    struct InstalledSkillMarker: Codable, Equatable {
      var version: String          // semver, e.g. "0.1.0"
      var installedAt: Date        // ISO 8601 encoded via JSONEncoder.dateEncodingStrategy = .iso8601
      var source: MarkerSource     // copy | symlink
      var bundlePath: String
      var bundleSha256: String
      enum MarkerSource: String, Codable { case copy, symlink }
    }

    enum InstallError: Error, Equatable {
      case destinationExistsNoMarker(URL)      // prompt or --force
      case destinationExistsLocalEdits(URL)    // bundleSha256 mismatch
      case destinationOutsideHome(URL)         // security check
      case bundleMissing(URL)
      case symlinkIntoReadOnlyBundle(URL)      // non-fatal, warn only
    }

Copy path. `install(mode: .copy)` walks `bundleURL` with `FileManager.subpathsOfDirectory`. For each file: copy to the destination preserving mode; skip `.DS_Store`; follow no symlinks (the bundle has none). After copy, write the marker at `<destination>/.codans-skill.json` (design doc §Data Storage). If the destination already exists with a marker whose `version` equals the bundle version **and** whose `bundleSha256` equals `currentBundleSha256()`, return a no-op result with the existing marker.

Symlink path (DEC-1). `install(mode: .symlink)` creates `<destination>` as a symlink pointing at `bundleURL`. Because the symlink target is the read-only `Resources/codans-skill/` inside the `.app` bundle, the marker cannot live inside the installed directory. Instead, the marker is written at `<destination>.marker.json` in the *parent* directory (e.g. `~/.claude/skills/codans.marker.json` next to the `codans` symlink). This deviation from design doc §Data Storage is called out in DEC-1. `readMarker(at: destination)` is a single entry point that hides the difference: if `destination` resolves to a symlink, it reads the sibling marker; otherwise it reads `<destination>/.codans-skill.json`. Callers (CLI + banner) never branch on mode.

Full re-copy on `--force` (DEC-6). When the user passes `--force` (or accepts the overwrite prompt), `SkillInstaller` removes the entire installed directory (via `removeItem`) and re-materialises from the bundle. No diff-based patching. The cost is a small directory rewrite (~18 tiny markdown files) — well under 100ms on any machine — and it eliminates an entire class of partial-state bugs.

Hash computation. `directorySha256(at:)` walks the tree in sorted path order (bytewise `<` on relative POSIX paths), and for each regular file appends `<relative_path_bytes>\0<file_mode_octal_bytes>\0<file_size_decimal_bytes>\0<file_contents>\0` into a streaming `SHA256` (CryptoKit `SHA256`, not `Insecure.*`). Directories appear as their children only. Non-regular files fail the hash with a thrown error. `currentBundleSha256()` is `directorySha256(at: bundleURL)`. Determinism is tested with a fixed fixture.

Drift detection. On `install(mode: .copy)` with an existing same-version marker but `directorySha256(at: destination)` ≠ marker's `bundleSha256`, throw `InstallError.destinationExistsLocalEdits` unless `options.force`.

Security check. `destination` must resolve (after `.standardizedFileURL`) to a path under `NSHomeDirectory()`. Otherwise throw `destinationOutsideHome`.

Dry-run. `options.dryRun == true` returns an `InstallResult` populated as if the copy had happened (same marker, same `filesWritten`) without touching the FS.

`SkillFileSystem.swift` — a small protocol with the operations `SkillInstaller` uses (`fileExists`, `isDirectory`, `createDirectory`, `copyItem`, `removeItem`, `createSymbolicLink`, `destinationOfSymbolicLink`, `attributesOfItem`, `contents`, `subpathsOfDirectory`). Default conforming type wraps `FileManager.default`. Tests inject a `FakeFileSystem` backed by an in-memory dictionary.

`apps/mac/codans/Tests/SkillInstallerTests.swift` (add to the `tcTests` target from M2). Cases:

- Install-by-copy into a tempdir produces the full tree + marker; marker's `bundleSha256` matches `currentBundleSha256()`.
- Reinstall same version, no edits → no-op (no files rewritten, marker timestamp unchanged).
- Reinstall same version, edited file → throws `destinationExistsLocalEdits` without `force`. With `--force`: the installer removes the whole installed directory and re-copies (per DEC-6); the edited file is gone, the marker's `bundleSha256` equals `currentBundleSha256()`, and `filesWritten` contains every bundle file (i.e. a full re-copy, not a partial patch).
- Reinstall different version → removes old tree, installs new, new marker.
- Install into existing non-skill directory → throws `destinationExistsNoMarker` unless `force`.
- Install outside HOME → throws `destinationOutsideHome`.
- Uninstall removes the directory and the marker; running it twice on an already-clean destination is a no-op.
- Symlink mode creates a symlink, writes `.marker.json` in the parent, and rehydrates via `readMarker`.
- Hash determinism: given the same fixture tree, `directorySha256` is byte-equal across 100 invocations and across two different fixture mounts.
- Dry-run returns a result without modifying the FS (`FakeFileSystem.mutationCount == 0`).

**Observable acceptance.**

- `xcodebuild test -scheme tcTests | xcbeautify` ends green with at least 15 test cases executed.
- `make mac-lint` is clean.
- A manual end-to-end invocation from a dev build (M4 wraps this; in M3, exercise via a temporary `codans debug skill-install` that calls `SkillInstaller.install(to: /tmp/codans-test, mode: .copy, options: .init())` — delete the debug hook before committing) produces `/tmp/codans-test/SKILL.md` and `/tmp/codans-test/.codans-skill.json` with a valid `bundleSha256`.

**Expected commits.** Three commits: `feat(codans): SkillBundleLocator with bundle and dev-run resolution`, `feat(codans): SkillInstaller copy + symlink + marker + drift detection`, `test(codans): SkillInstaller full coverage incl. hash determinism`.

### Milestone 4: `codans skill` subcommands + runners + CLI-level tests

**Goal after this milestone.** The CLI surface from design doc §API Design is live **in the `codans` binary only** — the app target is not touched. `codans skill install --claude-code` copies the bundled skill into `~/.claude/skills/codans/`. `codans skill install --codex` does the equivalent for Codex. `codans skill install --pi` invokes `pi install git:<mirrorURL>` and forwards its exit code. `codans skill uninstall`, `codans skill status`, and `codans skill bundle-path` all work. The `tcTests` bundle from M2 gains full coverage of every runner. The app-side banner is M5.

**Work.** Under `apps/mac/codans/`, create `SkillCommand.swift`:

    struct SkillCommand: ParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "Install, inspect, and remove the codans agent skill.",
        subcommands: [Install.self, Uninstall.self, Status.self, BundlePath.self]
      )
    }

    extension SkillCommand {
      struct Install: ParsableCommand { /* flags defined below */ }
      struct Uninstall: ParsableCommand { /* --agent */ }
      struct Status: ParsableCommand { /* --json */ }
      struct BundlePath: ParsableCommand { /* prints SkillBundleLocator result */ }
    }

Agent-flag wiring (DEC-7). ArgumentParser's default would turn `AgentID.claudeCode` into `--claudeCode`. The CLI contract requires `--claude-code`. Extend `AgentID` with an `EnumerableFlag` conformance that pins explicit names:

    extension AgentID: EnumerableFlag {
      static func name(for value: AgentID) -> NameSpecification {
        switch value {
        case .claudeCode: return .customLong("claude-code")
        case .codex:      return .customLong("codex")
        case .pi:         return .customLong("pi")
        }
      }
      static func help(for value: AgentID) -> ArgumentHelp? {
        switch value {
        case .claudeCode: return "Claude Code (~/.claude/skills/codans)"
        case .codex:      return "Codex CLI (~/.codex/skills/codans)"
        case .pi:         return "pi (via `pi install` against the mirror repo)"
        }
      }
    }

Each subcommand then takes `@Flag var agent: AgentID` and ArgumentParser emits mutually-exclusive `--claude-code | --codex | --pi` flags.

Wire `SkillCommand` into `CodansCLI.configuration.subcommands` in `apps/mac/codans/main.swift` (currently minimal per the bootstrap). Each subcommand runs its own logic synchronously; none of them opens an IPC socket. This is the Decision 10 invariant: `codans skill ...` is the only `codans` subcommand that bypasses IPC.

Install flow. Parse the agent flag into `AgentID`. Load `AgentsConfig` via `SkillBundleLocator.locateAgentsJSON`. Resolve the destination:

- For copy-mode agents (`claude-code`, `codex`): destination is `--dest` if given, else `config.defaultPath(for: agent, os: .darwin)` expanded against `NSHomeDirectory()`. Enforce the "under HOME" check (DEC-4 — repeated here as the CLI layer; `SkillInstaller` also enforces).
- For `pi` (`installMode: .piInstall`): refuse `--dest` with a clear error; refuse `--link`; otherwise build `pi install git:\(config.mirrorURL(for: .pi)!)` and dispatch via `Process`. Environment is inherited (so `PATH` finds the user's `pi`). On `pi` not found (exit 127 or `launchPath not a launchable binary`), exit with code 2 and a message: "pi binary not on PATH — install from https://mariozechner.github.io/pi/ then retry."

Install output. Default output is human text (one line per file written in dry-run, a summary line otherwise). `--json` emits `{"agent": "claude-code", "destination": "/Users/…", "version": "0.1.0", "mode": "copy", "result": "installed|noop|updated"}`.

Interactive prompts. Overwrite-prompt when destination exists with no marker or with local edits uses `readLine()` after printing the prompt to stderr. `--force` skips. When `stdin` is not a TTY and `--force` is not set, fail with a message instead of silently aborting.

Uninstall flow. Resolve destination for the agent (pi's path is resolved by asking `pi where` if pi is installed; otherwise report "pi-managed; use `pi remove` to uninstall"). Call `SkillInstaller.uninstall(at:)`.

Status flow. For each `AgentID.allCases`:

- claude-code/codex: resolve destination; attempt `SkillInstaller.readMarker`; record agent, installed version (or nil), bundle version (from `codans-skill/VERSION` as read by `SkillBundleLocator`), mode, path.
- pi: invoke `pi list --json` (if available) or parse `pi where` output to detect whether the mirror repo is present; record the version pi reports; mark the row with `(pi)` suffix.

Render the table (human) or JSON array (`--json`). Design doc §API Design pins the table shape; follow it. Unknown version between installed and bundled is flagged with a trailing `*` in human output.

Bundle-path flow. Print `try SkillBundleLocator.locateSkillBundle().path`. Exit 0 on success, exit 1 with a stderr message on `LocatorError`.

Extend `apps/mac/codans/Tests/` with `SkillCommandTests.swift`. Because `ParsableCommand` is awkward to unit-test directly, wrap each subcommand's logic in a pure `Runner` struct (`InstallRunner`, `UninstallRunner`, `StatusRunner`, `BundlePathRunner`) and test the runners. Tests cover: install-claude-code into temp dest writes tree and marker; install-codex prints JSON with `--json`; install-pi with missing `pi` binary exits code 2 (stub the `Process`-spawner via a protocol); uninstall-claude-code is idempotent; status emits a deterministic table against a fixture; the `EnumerableFlag` emits `--claude-code` / `--codex` / `--pi` in `codans skill install --help` output (string-match check).

**Observable acceptance.**

- Build the app: `make mac-build`. The `codans.app` binary contains a `codans` binary at `Contents/MacOS/codans`. Running `Contents/MacOS/codans skill --help` prints the four subcommands.
- `Contents/MacOS/codans skill install --help` prints `--claude-code`, `--codex`, `--pi` (not `--claudeCode`).
- From a shell in the repo root after bootstrap, `DERIVED=$(find ~/Library/Developer/Xcode/DerivedData -name 'codans.app' -type d | head -1); "$DERIVED/Contents/MacOS/codans" skill install --claude-code --dest /tmp/codans-skill-test --force` completes in < 1s and `/tmp/codans-skill-test/SKILL.md` + `/tmp/codans-skill-test/.codans-skill.json` exist.
- `"$DERIVED/Contents/MacOS/codans" skill status` prints the three-row table; absent any real install, all three rows show `-`.
- `"$DERIVED/Contents/MacOS/codans" skill bundle-path` prints an absolute path ending in `/Contents/Resources/codans-skill`.
- `xcodebuild test -scheme tcTests | xcbeautify` is green.
- `grep -rn 'SkillCommand\|SkillInstaller' apps/mac/codans/` returns no matches (the app target has not imported any of the CLI types — that's M5's job for a strictly limited piece).

**Expected commits.** Two commits: `feat(codans): skill install|uninstall|status|bundle-path subcommands with EnumerableFlag`, `test(codans): runner-level coverage for skill subcommands`.

### Milestone 5: `SkillVersionBanner` app-side component

**Goal after this milestone.** On app launch, `SkillVersionBanner` reads exactly one field — `version` — from each agent's install marker and posts a non-blocking SwiftUI banner when the installed version lags the bundled version. Dismissal is sticky per bundle version via `UserDefaults`. The banner touches zero skill content — not `SKILL.md`, not any `references/*.md` — only the marker's `version` string.

This milestone is separated from M4 because it is entirely UI-facing (SwiftUI + `@Observable`) and has a different reviewer focus (accessibility, SwiftUI lifecycle, `UserDefaults` persistence). Keeping it independent keeps the diff small.

**Work.** Under `apps/mac/codans/App/`, create `SkillVersionBanner.swift`:

    @MainActor @Observable
    final class SkillVersionBanner {
      enum Status: Equatable {
        case hidden
        case needsUpgrade(agent: AgentID, installed: String, bundled: String)
      }
      private(set) var status: Status = .hidden
      init(
        bundle: Bundle = .main,
        fileSystem: SkillFileSystem = RealSkillFileSystem(),
        defaults: UserDefaults = .standard
      )
      func check() async
      func dismiss()
    }

The minimal `InstalledSkillMarker` decoder lives in this file — a file-scoped `private struct MinimalMarker: Decodable { let version: String; enum CodingKeys: String, CodingKey { case version } }`. This file does **not** import `SkillInstaller`. Scope is a single field, per design doc §Data Storage §3.

Resolution:

1. `check()` loads `AgentsConfig.loadFromMainBundle()` (from M2, now delegating to `SkillBundleLocator` after M3).
2. Reads the bundled version from `codans-skill/VERSION` (via `Bundle.main.url(forResource: "VERSION", withExtension: nil, subdirectory: "codans-skill")`).
3. For each `AgentID.allCases`, resolves the default install path (expanded against HOME) and, if present, decodes the marker's `version` via `MinimalMarker`.
4. If any installed version lags the bundled version **and** the user has not dismissed that exact `(agent, bundled)` pair, set `status = .needsUpgrade(…)` and stop at the first mismatch (one banner at a time).

Dismissal. `dismiss()` writes the current bundled version to `UserDefaults` under key `Codans.SkillBannerDismissedVersions.<agent-raw>` and resets `status` to `.hidden`. The banner reappears on the next `check()` only if the bundled version changes (rewriting the key's value).

Lifecycle. Instantiate one `SkillVersionBanner` in the root TCA store setup (or at `CodansApp.init` pre-TCA if TCA is not yet in place — per exec plan 0002 M5 TCA is introduced; if 0004 lands before 0002 M5, use a plain `@StateObject`-style wrapper). Run `check()` as a `Task` attached to the root `WindowGroup.onAppear`. The banner view is a small SwiftUI component rendered above the main content, styled to look like a standard macOS banner (non-modal, dismissible, not blocking input).

Testing. Add `apps/mac/codans/Tests/SkillVersionBannerTests.swift` to the existing `codansTests` target (exec plan 0002 M2 introduced it). Use an in-memory `SkillFileSystem` + `UserDefaults(suiteName: UUID().uuidString)` for hermeticity. Cases:

- No markers present → `status == .hidden`.
- Marker version equals bundle version → `.hidden`.
- Marker version lags bundle version → `.needsUpgrade`.
- After `dismiss()`, next `check()` with the same bundle version stays `.hidden`; bumping the bundle version rearms the banner.
- Corrupt marker JSON (e.g. missing `version`) → treated as "not installed" (`.hidden` unless other agents mismatch); log a warning but do not crash.

**Observable acceptance.**

- Running the app after M4 produced an install at an older version → the banner appears with the correct agent name and version pair.
- Clicking the banner's dismiss action hides it; relaunching does not restore it until `codans-skill/VERSION` is bumped.
- `xcodebuild test -scheme codans | xcbeautify` is green; the new test cases appear in the output.
- `grep -rn 'SKILL.md\|references/' apps/mac/codans/` returns empty (the banner reads only the marker's `version`, nothing else).

**Expected commits.** Two commits: `feat(app): SkillVersionBanner with minimal-marker decoder`, `test(app): SkillVersionBanner coverage incl. dismissal persistence`.

### Milestone 6: Tier-A tests + version stamping + orthogonality check

**Goal after this milestone.** CI runs a Tier-A test suite on every PR that proves the skill documentation and the `codans` CLI are consistent and that `SkillInstaller` produces the documented artefact shape. A `generate-skill-version.sh` script syncs `codans`'s version into `codans-skill/VERSION` + `package.json` on release. A GitHub Actions workflow pushes `codans-skill/` to the mirror repo on every tagged release, keeping the mirror a faithful derived artefact.

**Work.**

`apps/mac/scripts/generate-skill-version.sh`:

    #!/usr/bin/env bash
    set -euo pipefail
    ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
    VERSION="${1:-$(awk -F'"' '/let version/ {print $2; exit}' "$ROOT/apps/mac/codans/main.swift")}"
    [ -n "$VERSION" ] || { echo "generate-skill-version: no version" >&2; exit 1; }
    echo "$VERSION" > "$ROOT/codans-skill/VERSION"
    # Rewrite package.json version with a small jq invocation
    tmp="$(mktemp)"
    jq --arg v "$VERSION" '.version = $v' "$ROOT/codans-skill/package.json" > "$tmp"
    mv "$tmp" "$ROOT/codans-skill/package.json"
    echo "skill: version pinned to $VERSION"

Wire into `apps/mac/Makefile` as `skill-version`; forward from the top-level `Makefile` as `mac-skill-version`. Also add `mac-skill-validate` which runs the Tier-A test harness (described below).

Tier-A test harness. Create `apps/mac/scripts/skill-tier-a.sh`:

    #!/usr/bin/env bash
    set -euo pipefail
    ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    TC="${TC_BIN:-$ROOT/apps/mac/.build/codans-release/codans}"
    [ -x "$TC" ] || { echo "codans binary not found at $TC"; exit 1; }

    # 1. --help roundtrip: every `codans <subcmd>` in references/codans-cli.md must appear in `codans --help-json`.
    "$TC" --help-json > "$TMP/help.json"
    python3 "$ROOT/apps/mac/scripts/skill-help-roundtrip.py" \
      "$ROOT/codans-skill/references/codans-cli.md" "$TMP/help.json"

    # 2. Install-into-tempdir + golden manifest diff
    "$TC" skill install --claude-code --dest "$TMP/target" --force --json > "$TMP/install.json"
    (cd "$TMP/target" && find . -type f | sort) > "$TMP/manifest.txt"
    diff -u "$ROOT/apps/mac/scripts/skill-golden-manifest.txt" "$TMP/manifest.txt"

    echo "tier-A: all checks passed"

`skill-help-roundtrip.py` parses code fences in `references/codans-cli.md` for lines matching `codans <subcommand>…`, extracts the subcommand tokens, and asserts each is present in the `--help-json` output. Unknown tokens fail with an exit code and a diff.

`codans --help-json` is a new flag on `CodansCLI` that prints a machine-readable dump of every subcommand and its flags. `ArgumentParser` does not provide this directly; add a small Command subclass that walks `configuration.subcommands` recursively and emits JSON. Implementation is ~30 lines. Shipping it also benefits future CLI documentation.

`skill-golden-manifest.txt` is the sorted file list after a fresh `codans skill install --claude-code --force` into a clean tempdir (omitting the install marker, whose name is stable but whose content is timestamped). Regenerate whenever M1 or M8 intentionally change the package *file set* via `make mac-skill-golden-update` (a wrapper that runs the installer and copies the manifest). Content-only changes should leave the golden untouched.

CI wiring. Create `.github/workflows/skill-tier-a.yml` that runs on PR and push to main. Steps:

1. `actions/checkout@v4` with `submodules: recursive`.
2. Install `mise`, `tuist`, `jq`, `python3`.
3. `make mac-bootstrap` (existing; performs `mise install`).
4. `make mac-build` (Release flavour to produce an unsigned `codans` binary).
5. `make mac-skill-validate` which calls `skill-tier-a.sh`.

Tier-A runs without the app being "running" — it operates entirely on the built `codans` binary and filesystem fixtures. This is the independence promised in design doc §Testing Strategy.

Orthogonality check. Add `apps/mac/scripts/skill-orthogonality-check.sh`:

    #!/usr/bin/env bash
    set -euo pipefail
    ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
    # No source under the app/core targets may grep for SKILL.md or read codans-skill/*
    # except through SkillBundleLocator / SkillInstaller / AgentsConfig / SkillVersionBanner.
    matches=$(grep -rn "SKILL.md\|codans-skill/" \
      apps/mac/CodansCore apps/mac/CodansIPC apps/mac/codans \
      --include='*.swift' \
      | grep -v 'SkillBundleLocator\|SkillInstaller\|AgentsConfig\|SkillVersionBanner\|SkillCommand' \
      || true)
    [ -z "$matches" ] || { echo "orthogonality violation:\n$matches" >&2; exit 1; }

Hooked into `make mac-skill-validate` so CI fails on unauthorised access.

**Observable acceptance.**

- Locally: `make mac-skill-validate` exits 0 on a clean checkout after M5.
- On a test branch: push a PR; the `skill-tier-a.yml` workflow runs to green.
- Orthogonality: deliberately add `import Foundation; let x = "codans-skill/SKILL.md"` in `apps/mac/codans/App/CodansApp.swift`; `make mac-skill-validate` fails with the grep output; reverting restores green.

**Expected commits.** Three commits: `chore(skill): generate-skill-version.sh + Makefile wiring`, `feat(codans): --help-json for machine-readable CLI dump`, `ci(skill): tier-A workflow + orthogonality check script`.

### Milestone 7: Mirror-repo release automation

**Goal after this milestone.** On every tagged release (`v*`), a GitHub Actions workflow pushes `codans-skill/` to a separate mirror repository, producing a git commit tagged with the same version. The mirror is the only path by which `pi install git:...` consumers receive the skill. Branch protection on the mirror repo forbids manual commits; the deploy key used by the workflow is the sole writer.

This milestone is split from M6 because it depends on owner-level actions that the plan implementer cannot perform from code alone:

1. Create the mirror repository at `github.com/wanggang316/codans-skill` (Decision 12).
2. Generate a Deploy Key (SSH) with write access on the mirror; add its **public** part to the mirror's repo Settings → Deploy Keys, and its **private** part as a secret named `MIRROR_DEPLOY_KEY` on *this* repo's Settings → Secrets.
3. Enable branch protection on the mirror's `main` so only the deploy key can write.

Steps 1-3 are documented in the workflow header comment; M7 is considered complete when the workflow runs green against a dry tag on a scratch branch. Until the owner has done steps 1-3, the workflow exists but is expected to fail — that is an acceptable state of M7 for as long as the owner has not yet released.

**Work.** Create `.github/workflows/mirror-skill.yml` triggered on `push: tags: ['v*']`:

1. `actions/checkout@v4` with full history.
2. Verify the pushed tag name matches the version written in `codans-skill/VERSION` (fail if not — prevents mislabelled tags).
3. Install the `MIRROR_DEPLOY_KEY` secret into `~/.ssh/id_ed25519`; add `github.com` to known hosts.
4. Clone the mirror repo (`git@github.com:wanggang316/codans-skill.git`) into `$TMP/mirror`.
5. Rsync `codans-skill/` over `$TMP/mirror/` with `--delete` (so removed source files are removed in the mirror).
6. In `$TMP/mirror`, `git add -A`; if there is no diff, log "no changes, skipping" and exit 0. Otherwise `git commit -m "Sync from wanggang316/codans@$TAG" && git tag $TAG && git push origin main --tags`.
7. Emit a workflow summary with the tagged commit SHA.

The `skill-orthogonality-check.sh` and `make mac-skill-validate` from M6 run as preflight before step 4, ensuring a misconfigured repo does not publish a broken mirror.

**Observable acceptance.**

- After owner steps 1-3 are complete: tag-simulation `git tag v0.0.1-test && git push origin v0.0.1-test` (on a throwaway branch) triggers `mirror-skill.yml`; the workflow runs to green; the mirror repo shows the new commit + tag; delete the tag and revert afterwards.
- Before owner steps are complete: the workflow exists on disk; pushing a tag triggers it; it fails at step 4 with a clear "host key verification failed" or "permission denied (publickey)" message. The failure is expected; the plan is complete for this milestone even while the workflow is still red, provided the YAML has been reviewed and merged.

**Expected commits.** One commit: `ci(skill): mirror-skill workflow with deploy-key publish`.

**Owner follow-up (outside the plan).** Complete the three setup steps before the first real release tag. Record the setup date in the Decision Log.

### Milestone 8: SKILL.md + `references/` production content pass

**Goal after this milestone.** Every stub from M1 has been replaced with production content. A new Claude Code / Codex / pi session inside a codans Pane can read `SKILL.md` and produce correct `codans` invocations without guessing. The content rules from design doc §SKILL.md Template are honoured: no Swift, no architecture diagrams, no rationale prose. CLI-only, recipe-rich.

**Work.** Rewrite each file. The content plan — not the content itself — is specified below so that a reviewer can confirm coverage without the plan becoming prescriptive of prose.

`SKILL.md`:

- Frontmatter (already correct from M1).
- One-sentence "Use this skill when …" line ported verbatim from the supaterm model (adapted to `codans`).
- **Terminology** section: one line per Space / Project / Worktree / Tab / Pane / Hook / Skill, matching the definitions in product-spec §Key Concepts verbatim (a direct quotation keeps the two in sync — when product-spec changes, M6-style refresh updates SKILL.md).
- **Fast Start** section: 8 commands covering `codans tree --json`, `codans worktree new <branch>`, `codans tab new --focus -- <cmd>`, `codans pane split right`, `codans pane send <id> 'echo hi'`, `codans open --in <editor>`, `codans agent install-hook claude`, `codans skill status`. Every command has an expected JSON or human output line.
- **Deep-Dive References** section: bulleted links to the six `references/*.md`.

`references/hierarchy-model.md`:

- Define the five-level tree in diagram form (ASCII), citing product-spec §Core Capabilities C2 verbatim.
- Selector syntax: `1` (Space), `1/2` (Project … wait; re-read product-spec to get ordering exactly) — the correct selector form follows whatever `codans tree` emits. Document the exact form the CLI accepts. Lock this at implementation time against `codans tree --json` output.
- Ambient env vars: `CODANS_PANE_ID`, `CODANS_SOCKET_PATH`, `CODANS_TAB_ID` (if exposed), `CODANS_WORKTREE_ID`. Cross-reference [architecture §IPC](../architecture.md).

`references/targeting-and-selectors.md`:

- Selector forms, UUIDs, `--in` conventions — adapt the supaterm `references/targeting-and-selectors.md` structure.
- Creation commands return typed IDs (`tabID`, `paneID`); list-commands use generic `id`.

`references/codans-cli.md`:

- One subsection per `codans` subcommand group: `codans tree`, `codans space *`, `codans worktree *`, `codans tab *`, `codans pane *`, `codans send`, `codans broadcast`, `codans open`, `codans agent *`, `codans skill *`. Each subsection shows the subcommand's usage line from `codans <subcmd> --help`, the parameters, and at least one example with expected output.
- This file is the target of the Tier-A `codans --help` roundtrip check. Every `codans <subcommand>` it mentions in a code block must exist in `codans --help-json`.

`references/agent-hooks.md`:

- Install hooks: `codans agent install-hook claude`, `codans agent install-hook codex`, `codans agent install-hook pi`. Document the files each touches (`~/.claude/settings.json`, `~/.codex/hooks.json`, pi equivalent). Cross-reference product-spec §C6.
- Remove hooks. Forward a hook event via `codans agent receive-agent-hook --agent <agent>`.

`references/worktrees-and-editors.md`:

- Create / list / remove worktrees via `codans worktree …`; default sibling `<repo>-worktrees/<branch>` layout (product-spec Open Q6 resolved by design doc 0001 §Component Boundaries).
- `codans open [--in <editor>]` to launch VSCode / Cursor / Zed / Xcode / Sublime Text / Finder. Per-Project default editor.

`references/recipes.md`:

- 5-7 worked multi-step recipes: "Start a dev server in a new Tab", "Broadcast a command to every Pane in the current Tab", "Create a worktree for feature branch X and open it in Cursor", "Notify when the current shell finishes a long command" (uses `codans pane notify` once the command returns), "List worktrees as JSON and pick one by name", "Install the skill into a fresh Claude Code session".

`agents/claude-code/README.md`:

- Where Claude Code finds this skill (`~/.claude/skills/codans/`); how to trigger it (no explicit command needed — Claude picks it up); how to verify (`/skills` inside Claude, or simply ask a `codans`-shaped question).
- Hook installation pointer: `codans agent install-hook claude` to wire notifications.
- Troubleshooting table (skill not picked up, skill stale, skill conflicts with user edits).

`agents/claude-code/examples.md`:

- 3-5 example prompts showing how Claude uses the skill: "Open a new pane running htop", "Broadcast `pwd` to every pane in this tab", "Create a worktree for branch `exp/foo`", "Show which worktrees are idle", "Install the agent hook so I get notified".

`agents/codex/README.md`, `.../codex/examples.md` — same shape.

`agents/pi/README.md`:

- Install instructions: `pi install git:github.com/wanggang316/codans-skill` (Decision 12 URL), or use `codans skill install --pi` which wraps this.
- How pi discovers the skill (package.json `pi.skills`).
- Pointer to a future `pi-notify-codans` extension (O1 — out of scope for this plan).

`agents/pi/examples.md` — 3 example prompts adapted to pi's CLI shape.

`tests/claude-code.smoke.md`, `tests/codex.smoke.md` — remain stubs; fleshed out in M7.

Regex-delete all `<!-- STUB: filled in by exec plan 0004 M8 -->` markers. A passing grep `grep -rn 'STUB: filled in by' codans-skill` returning zero matches is part of observable acceptance.

After content lands, run `make mac-skill-golden-update` and verify `git diff apps/mac/scripts/skill-golden-manifest.txt` is empty. File names are stable since M1; M8 edits content only, so the manifest should not change. A non-empty diff means the file *set* drifted — stop and reconcile against design doc §Package Structure before continuing.

**Observable acceptance.**

- `grep -rn 'STUB: filled in by' codans-skill` → zero output.
- `grep -rn 'import ' codans-skill` → zero output (no accidental Swift references).
- `make mac-skill-validate` stays green (content change must not break the Tier-A checks — confirms `references/codans-cli.md` is in sync with `codans --help-json`).
- Manual review against design doc §Anti-example: no Swift-level references; no architecture diagrams; no rationale prose.
- Word count heuristic: `SKILL.md` + `references/*.md` totals between 1500 and 4000 words. Shorter suggests stubs remain; longer suggests content-over-reach.

**Expected commits.** Four commits: `docs(skill): production SKILL.md + references/hierarchy-model + targeting`, `docs(skill): references/codans-cli + agent-hooks + worktrees-and-editors`, `docs(skill): recipes.md`, `docs(skill): per-agent READMEs and example recipes`.

### Milestone 9: Tier-B per-agent smoke tests + release gate

**Goal after this milestone.** A release tag cannot be cut until Tier-B tests show each agent can drive `codans` via the installed skill. Tier-B tests are written, documented, and gated on the release-tag CI. Where the underlying `codans` surface is not yet live (e.g. `codans tree`, `codans pane …` require exec plan 0002 to land further milestones), the Tier-B test uses the closest realisable command and is marked `skip-unless-feature`.

**Work.**

`codans-skill/tests/claude-code.smoke.md`:

- Document the invocation: from a codans Pane, run `claude` non-interactively with a fixed prompt, expect a specific `codans` invocation in the response.
- The test harness lives in `apps/mac/scripts/skill-tier-b-claude.sh`. **Note.** The exact non-interactive invocation for Claude Code (`claude -p "..."` vs. `claude --print "..."` vs. piped stdin) is evolving; the script below is a **skeleton** — verify the flag at release time by running `claude --help` on the CI runner. The logic around tier-A fallback (DEC-5) is stable and must be preserved when the invocation is updated.

      #!/usr/bin/env bash
      set -euo pipefail
      # Assumes: codans.app running; `claude` CLI on PATH; skill installed via codans skill install --claude-code
      tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT
      PROMPT='List all panes as JSON and report the count.'
      # SKELETON — verify the real non-interactive invocation against `claude --help` at release time.
      OUTPUT=$(claude -p "$PROMPT" 2>"$tmpdir/stderr")
      grep -q 'codans tree --json' <<< "$OUTPUT" || { echo "claude did not reference codans tree --json"; exit 1; }
      # If codans tree is wired (post-0002 M5+), compare Claude's counted number to the authoritative count.
      if codans tree --json >"$tmpdir/ls.json" 2>/dev/null; then
        expected=$(jq '.panes | length' < "$tmpdir/ls.json")
        claude_count=$(grep -Eo '[0-9]+' <<< "$OUTPUT" | tail -1)
        [ "$expected" = "$claude_count" ] || { echo "count mismatch"; exit 1; }
      else
        echo "codans tree not yet wired; skill reference check alone passes"
      fi
      echo "claude-code smoke passed"

`codans-skill/tests/codex.smoke.md` + `apps/mac/scripts/skill-tier-b-codex.sh` — analogous shape against Codex. Same skeleton caveat: verify Codex's non-interactive flag at release time (`codex --help`); the current exec options are `codex exec "..."` or stdin-piped.

`codans-skill/tests/pi.smoke.sh` — existing stub becomes the real harness. Same skeleton caveat: pi's non-interactive invocation is `pi -p "..."` as of 2026-04; re-verify at release time.

    #!/usr/bin/env bash
    set -euo pipefail
    # 1. Install via pi
    pi install git:github.com/wanggang316/codans-skill
    # 2. Run a canned pi prompt — SKELETON; verify flag via `pi --help` at release time.
    tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT
    pi -p "What is the command to open a new tab in codans?" \
      | tee "$tmpdir/out.txt" \
      | grep -q 'codans tab new'
    echo "pi smoke passed"

Add `.github/workflows/skill-tier-b.yml` triggered on `push: tags: ['v*']`. Steps:

1. Checkout with submodules.
2. Install `mise`, the release `codans` binary, `claude` CLI, `codex` CLI, `pi` CLI.
3. Launch `codans.app` in headless mode (`open -na codans.app --args --headless` — a mode added in a future plan; for now, Tier-B may be run on self-hosted macOS runners with a real desktop session).
4. `codans skill install --claude-code --force && codans skill install --codex --force && codans skill install --pi --force`.
5. Run the three Tier-B scripts in sequence. Any non-zero exit fails the release build.

Because Tier-B needs real agent binaries and a real desktop session, v1 runs it on a self-hosted macOS runner. Document the runner setup in `.github/workflows/skill-tier-b.yml`'s header comment (required: Xcode, `claude`, `codex`, `pi`, a configured user account). If a Tier-B dependency is missing (e.g. `codex` not yet available in this environment), the workflow `skip`s that agent's test with a visible warning but does not fail.

`make mac-skill-tier-b` wires the local equivalent for hand-run verification.

**Observable acceptance.**

- On a self-hosted runner with all dependencies present, pushing a tag `v0.1.0` runs the Tier-B workflow and produces a workflow summary showing "claude-code smoke passed", "codex smoke passed", "pi smoke passed".
- Absence of the app's `codans tree` implementation degrades gracefully: the claude-code test still passes on the "skill reference check alone" branch, with a visible warning in the summary.
- Locally: `make mac-skill-tier-b` runs end-to-end on the author's machine.

**Expected commits.** Three commits: `test(skill): tier-B claude-code smoke`, `test(skill): tier-B codex smoke`, `test(skill): tier-B pi smoke + release-tag workflow`.

## Concrete Steps

Run every command from the repository root (`/Users/wanggang/dev/00/codans`) unless otherwise noted. Steps are grouped by milestone. Keep the Progress section updated as each step completes.

### M1 steps

    mkdir -p codans-skill/{references,agents/claude-code,agents/codex,agents/pi,tests}
    # Create stub files in the shape listed under "Work" for M1.
    chmod +x codans-skill/tests/pi.smoke.sh
    find codans-skill -type f | sort
    # Expected: 18 lines covering every file in design doc §Package Structure
    git add codans-skill && git commit -m "feat(skill): scaffold codans-skill/ tree with stub content"

### M2 steps

    # Create apps/mac/Resources/agents.json with the Data Storage schema
    plutil -lint apps/mac/Resources/agents.json
    # Expected: OK
    make mac-generate
    # Implement AgentsConfig.swift + tests
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/codans.xcworkspace \
                      -scheme tcTests | xcbeautify
    # Expected: at least 5 test cases green
    make mac-build
    ls "$(find ~/Library/Developer/Xcode/DerivedData -name 'codans.app' -type d | head -1)/Contents/Resources/agents.json"
    # Expected: path prints

### M3 steps

    make mac-generate
    # Implement SkillBundleLocator.swift, SkillInstaller.swift, SkillFileSystem.swift, tests
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/codans.xcworkspace \
                      -scheme tcTests | xcbeautify
    # Expected: ≥ 15 test cases green (15 new SkillInstaller + 5 AgentsConfig from M2)

### M4 steps

    make mac-generate
    # Implement SkillCommand.swift + runners + main.swift dispatch + SkillCommandTests
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/codans.xcworkspace \
                      -scheme tcTests | xcbeautify
    make mac-build
    DERIVED=$(find ~/Library/Developer/Xcode/DerivedData -name 'codans.app' -type d | head -1)
    "$DERIVED/Contents/MacOS/codans" skill --help
    "$DERIVED/Contents/MacOS/codans" skill install --help | grep -E -- '--claude-code|--codex|--pi'
    # Expected: the three flags are present (not --claudeCode)
    "$DERIVED/Contents/MacOS/codans" skill install --claude-code --dest /tmp/codans-skill-test --force
    ls /tmp/codans-skill-test/SKILL.md /tmp/codans-skill-test/.codans-skill.json
    # Expected: both files present
    "$DERIVED/Contents/MacOS/codans" skill status
    # Expected: three-row table
    "$DERIVED/Contents/MacOS/codans" skill bundle-path
    # Expected: absolute path ending in /Contents/Resources/codans-skill
    rm -rf /tmp/codans-skill-test
    grep -rn 'SkillCommand\|SkillInstaller' apps/mac/codans/ || true
    # Expected: no matches (app target has not been touched yet)

### M5 steps

    make mac-generate
    # Implement SkillVersionBanner.swift + SkillVersionBannerTests.swift
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/codans.xcworkspace \
                      -scheme codans | xcbeautify
    # Expected: new banner test cases visible in output, all green
    make mac-run-app
    # Expected: with a stale-version marker pre-written at ~/.claude/skills/codans/.codans-skill.json,
    #           a non-blocking banner appears on launch

### M6 steps

    chmod +x apps/mac/scripts/generate-skill-version.sh apps/mac/scripts/skill-tier-a.sh \
             apps/mac/scripts/skill-orthogonality-check.sh apps/mac/scripts/skill-help-roundtrip.py
    ./apps/mac/scripts/generate-skill-version.sh 0.1.0
    cat codans-skill/VERSION
    # Expected: "0.1.0"
    jq -r .version codans-skill/package.json
    # Expected: "0.1.0"
    make mac-skill-validate
    # Expected: "tier-A: all checks passed"
    ./apps/mac/scripts/skill-orthogonality-check.sh
    # Expected: no output, exit 0

### M7 steps (owner-gated)

    # One-time owner actions (outside any CI):
    #   1. Create github.com/wanggang316/codans-skill (empty repo, main branch, branch-protected).
    #   2. Generate deploy key: ssh-keygen -t ed25519 -f ~/.ssh/codans-mirror-deploy (no passphrase).
    #   3. Add public key to the mirror repo Settings → Deploy keys (grant "write access").
    #   4. Add private key to THIS repo Settings → Secrets → MIRROR_DEPLOY_KEY.
    # Then land the workflow file:
    #   .github/workflows/mirror-skill.yml
    # Validate against a scratch branch:
    git checkout -b mirror-smoke
    git tag v0.0.1-mirror-smoke && git push origin mirror-smoke --tags
    # Expected: mirror-skill.yml runs green; mirror repo shows the new commit + tag
    # Clean up:
    git push --delete origin v0.0.1-mirror-smoke
    git tag -d v0.0.1-mirror-smoke

### M8 steps

    # Rewrite SKILL.md + references/*.md + agents/**/README.md with production content.
    grep -rn 'STUB: filled in by' codans-skill
    # Expected: no matches
    make mac-skill-validate
    # Expected: "tier-A: all checks passed"
    make mac-skill-golden-update
    # Expected: script regenerates skill-golden-manifest.txt; `git diff` shows zero changes
    # (file names are stable since M1; M8 edits content only).
    # If a diff appears, it means the file *set* changed — stop and reconcile with design doc §Package Structure.

### M9 steps

    chmod +x apps/mac/scripts/skill-tier-b-claude.sh apps/mac/scripts/skill-tier-b-codex.sh
    make mac-skill-tier-b
    # Expected on a fully provisioned host: three "smoke passed" lines
    # Expected on a partially provisioned host: the missing agents emit a warning; present agents pass

## Validation and Acceptance

After all nine milestones land, a fresh contributor can perform the following and observe the exact outputs:

1. `make mac-bootstrap && make mac-generate && make mac-build`. The build succeeds; `codans.app` contains `Contents/Resources/codans-skill/` and `Contents/Resources/agents.json`.
2. `"$(find ~/Library/Developer/Xcode/DerivedData -name 'codans.app' -type d | head -1)/Contents/MacOS/codans" skill install --claude-code`. Within one second, `~/.claude/skills/codans/` exists with a valid `SKILL.md` and `.codans-skill.json`.
3. `codans skill status --json | jq '.[] | select(.agent == "claude-code") | .installed'` prints the installed version string (matches `VERSION`).
4. `codans skill install --claude-code` (second invocation) reports no-op (idempotence).
5. `echo 'deliberately edited' >> ~/.claude/skills/codans/SKILL.md; codans skill install --claude-code` prompts for overwrite; `--force` skips the prompt and performs a full re-copy (DEC-6).
6. `codans skill uninstall --claude-code && codans skill status` shows the row back to `-`.
7. `codans skill install --pi` (with `pi` installed) completes; `pi list` shows `codans-skill`. Without `pi` installed, the command exits 2 with a clear message.
8. Launching the app with a stale-version marker triggers the `SkillVersionBanner`; dismissing it persists across launches until the bundle version is bumped.
9. `make mac-skill-validate` runs Tier-A and exits 0. Orthogonality check passes.
10. On a release-tag push (once M7 owner actions are complete), the `mirror-skill.yml` workflow succeeds and the mirror repo contains `codans-skill/` at the tagged commit.
11. On a release-tag push against a properly provisioned runner, `skill-tier-b.yml` completes; claude-code / codex / pi smoke tests pass (or degrade gracefully per DEC-5).
12. In a real Claude Code session inside a codans Pane, asking "how do I split this pane?" yields an answer that references `codans pane split …` by name (skill content pass).

Failure on items 1-9 blocks sign-off. Items 10-12 are release-time gates; M4 through M6 can ship without them fully green as long as the pipelines exist and Tier-A is clean.

## Idempotence and Recovery

Every milestone is designed to be re-runnable. Recovery rituals specific to C5:

- **Regenerate Xcode workspace.** `make mac-generate` is safe to run repeatedly.
- **Reset local skill install.** `codans skill uninstall --<agent>` returns the agent's skill directory to a clean state. For pi, `pi remove codans-skill` (or delete `~/.pi/agent/git/github.com/wanggang316/codans-skill/` manually).
- **Rehash and compare.** If drift detection misfires, `codans skill status --json` shows the installed version and path; the marker's `bundleSha256` can be diffed by re-running `codans skill install --claude-code --dry-run --json` and comparing the result marker against the one on disk.
- **Regenerate golden manifest.** `make mac-skill-golden-update` is the single blessed way to change the golden file. A diff in the golden is always a deliberate change.
- **Rewind a bad mirror push.** If `mirror-skill.yml` pushes a broken commit, open the mirror repo directly and `git reset --hard <previous-good>` with a force-push — this is the only case where force-pushing to the mirror is acceptable, and it is explicitly an owner action (not automated). The `MIRROR_DEPLOY_KEY` has branch-protection override for this case only.
- **Reset the app's dismissed banners.** `defaults delete <bundle-id> Codans.SkillBannerDismissedVersions.claude-code` re-enables the banner.
- **Full clean.** `rm -rf /tmp/codans-skill-* ~/.claude/skills/codans ~/.codex/skills/codans && codans skill status` should report three `-` rows. Re-run install to rehydrate.

None of the steps modify repository-wide state. `codans skill install` never writes outside `$HOME`; the security check in `SkillInstaller` is defence-in-depth.

## Artifacts and Notes

Prototyping findings that inform this plan:

- **supaterm-skills shape is directly portable.** Reading `/Users/wanggang/dev/opensource/supaterm-skills/skills/supaterm/` end-to-end confirms that the `SKILL.md` + `references/` + `agents/` shape is the one Claude Code and pi already expect. Deviations are additive (`VERSION`, `tests/`) and do not affect consumer compatibility.
- **pi install model is git-based.** `/Users/wanggang/.pi/agent/git/github.com/supabitapp/supaterm-skills/` exists and pi re-clones on update. This forces the mirror-repo approach for pi support — `codans skill install --pi` cannot simply copy files into pi's cache because pi expects a real git remote to re-fetch from.
- **CryptoKit `SHA256` is sufficient for `bundleSha256`.** A 16-file tree fits in well under 10ms on an M1 MacBook (benchmarked against the stub tree from M1). No streaming chunking needed for this size.
- **ArgumentParser supports the chosen subcommand shape directly.** `CommandConfiguration(subcommands: [...])` nests cleanly. Mutually exclusive flags (`--claude-code | --codex | --pi`) are modelled as a `@Flag` with an `EnumerableFlag` conformance on `AgentID`.
- **`--help-json` is a thin wrapper.** ArgumentParser exposes `CommandInfoV0` / `BashCompletionsGenerator` but no JSON dump out of the box; a 30-line walker over `Command.configuration.subcommands` is sufficient and reused by Tier-A's roundtrip check.

## Interfaces and Dependencies

The following types, functions, and signatures must exist by plan completion. Names are binding — later plans and the Tier-A golden checks will reference them.

**`codans-skill/`** (content-only, no Swift):

- `SKILL.md` — frontmatter keys `name: codans`, `description: Control codans spaces, projects, worktrees, tabs, and panes with \`codans\`.`
- `VERSION` — plain-text semver; generated by `apps/mac/scripts/generate-skill-version.sh`.
- `package.json` — `{ "name": "@codans/skill", "version": "<semver>", "pi": { "skills": ["./"] }, … }`.
- `references/{hierarchy-model,targeting-and-selectors,codans-cli,agent-hooks,worktrees-and-editors,recipes}.md`.
- `agents/{claude-code,codex,pi}/{README,examples}.md`.
- `tests/{claude-code,codex}.smoke.md`, `tests/pi.smoke.sh`.

**`apps/mac/Resources/agents.json`** — schema and content per design doc §Data Storage. Bundled as a resource.

**`apps/mac/codans/`** (Swift; depends on `CodansCore`, `CodansIPC`, `ArgumentParser`, `CryptoKit`, `Foundation`):

    enum AgentID: String, CaseIterable, Codable, Sendable { case claudeCode = "claude-code", codex, pi }
    extension AgentID: EnumerableFlag {
      static func name(for value: AgentID) -> NameSpecification           // .customLong("claude-code") etc.
      static func help(for value: AgentID) -> ArgumentHelp?
    }
    enum TargetOS: String, Sendable { case darwin, linux }
    enum AgentInstallMode: String, Codable, Sendable { case copy, piInstall = "pi-install" }

    struct AgentsConfig: Codable, Equatable, Sendable {
      static let currentVersion = 1
      var version: Int
      var agents: [String: AgentConfig]
      static func load(from url: URL, decoder: JSONDecoder = .default) throws -> Self
      static func loadFromMainBundle() throws -> Self
      func config(for agent: AgentID) -> AgentConfig?
      func defaultPath(for agent: AgentID, os: TargetOS) -> String?
      func mirrorURL(for agent: AgentID) -> String?
    }

    struct AgentConfig: Codable, Equatable, Sendable {
      var defaultPath: [String: String]?
      var mirrorURL: String?
      var installMode: AgentInstallMode
    }

    enum SkillBundleLocator {
      enum LocatorError: Error, Equatable { case bundleNotFound; case repoRootNotFound }
      static func locateSkillBundle(executableURL: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: "/")) throws -> URL
      static func locateAgentsJSON(executableURL: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: "/")) throws -> URL
    }

    protocol SkillFileSystem: Sendable { /* thin wrapper over FileManager: fileExists, isDirectory,
                                            createDirectory, copyItem, removeItem,
                                            createSymbolicLink, destinationOfSymbolicLink,
                                            attributesOfItem, contents, subpathsOfDirectory */ }
    struct RealSkillFileSystem: SkillFileSystem { /* FileManager.default */ }

    @MainActor struct SkillInstaller {
      let bundleURL: URL
      let fileSystem: SkillFileSystem
      func install(to destination: URL, mode: InstallMode, options: InstallOptions) throws -> InstallResult
      func uninstall(at destination: URL) throws
      func readMarker(at destination: URL) throws -> InstalledSkillMarker?
      func currentBundleSha256() throws -> String
      func directorySha256(at url: URL) throws -> String
    }

    enum InstallMode: Sendable { case copy, symlink }
    struct InstallOptions: Sendable { var force = false; var dryRun = false; var now: Date = Date() }
    struct InstallResult: Equatable, Sendable { let destination: URL; let marker: InstalledSkillMarker; let filesWritten: [URL] }

    struct InstalledSkillMarker: Codable, Equatable, Sendable {
      var version: String
      var installedAt: Date
      var source: MarkerSource
      var bundlePath: String
      var bundleSha256: String
      enum MarkerSource: String, Codable, Sendable { case copy, symlink }
    }

    enum InstallError: Error, Equatable, Sendable {
      case destinationExistsNoMarker(URL)
      case destinationExistsLocalEdits(URL)
      case destinationOutsideHome(URL)
      case bundleMissing(URL)
      case symlinkIntoReadOnlyBundle(URL)
    }

    struct SkillCommand: ParsableCommand {
      static let configuration: CommandConfiguration /* subcommands: Install, Uninstall, Status, BundlePath */
    }

    extension SkillCommand {
      struct Install: ParsableCommand { /* flags: agent, --dest, --link, --force, --dry-run, --json */ }
      struct Uninstall: ParsableCommand { /* flags: agent */ }
      struct Status: ParsableCommand { /* flag: --json */ }
      struct BundlePath: ParsableCommand { }
    }

    // For testability, each subcommand delegates to a pure runner:
    struct InstallRunner { let installer: SkillInstaller; let config: AgentsConfig; /* ... */ func run(...) throws -> InstallResult }
    struct StatusRunner   { /* ... */ }
    struct UninstallRunner { /* ... */ }

**`apps/mac/codans/App/`** (app target; depends on `CodansCore`, `CodansIPC`, `SwiftUI`, optionally `TCA`):

    @MainActor @Observable
    final class SkillVersionBanner {
      enum Status: Equatable { case hidden; case needsUpgrade(agent: AgentID, installed: String, bundled: String) }
      private(set) var status: Status = .hidden
      init(bundle: Bundle = .main, fileSystem: SkillFileSystem = RealSkillFileSystem())
      func check() async
      func dismiss()
    }

    // Private, file-scoped minimal marker decoder — reads only `version`.
    private struct MinimalMarker: Decodable { let version: String; enum CodingKeys: String, CodingKey { case version } }

**`apps/mac/scripts/`** (plan-introduced shell/python):

- `generate-skill-version.sh` — syncs `codans` version into `codans-skill/VERSION` + `package.json`.
- `skill-tier-a.sh` — `codans --help` roundtrip + golden manifest diff.
- `skill-help-roundtrip.py` — parses `references/codans-cli.md` + compares to `codans --help-json`.
- `skill-orthogonality-check.sh` — grep-based invariant check.
- `skill-golden-manifest.txt` — sorted file list; regenerated via `mac-skill-golden-update`.
- `skill-tier-b-claude.sh`, `skill-tier-b-codex.sh` — tier-B harnesses.

**`.github/workflows/`**:

- `skill-tier-a.yml` — runs on PR + push to main.
- `mirror-skill.yml` — runs on `push: tags: ['v*']`; requires `MIRROR_DEPLOY_KEY` secret.
- `skill-tier-b.yml` — runs on `push: tags: ['v*']`; requires self-hosted macOS runner with `claude`, `codex`, `pi` binaries.

**External dependencies added by this plan**: none new for the Swift side. `jq` and `python3` are required in CI; both are standard on the default GitHub runners. `ArgumentParser` is already a dep of `codans` (exec plan 0001).

**Tuist targets added or modified by this plan**:

- `tcTests` (new `.unitTests` target, host: `codans` binary). Covers `AgentsConfig`, `SkillBundleLocator`, `SkillInstaller`, `SkillCommand` runners.
- `codans` app target gains `agents.json` via `resources:`, and `codans-skill/` via `copyFiles` action (or equivalent Tuist mechanism) placing it at `Contents/Resources/codans-skill/`. `codans-skill/` is **not** a Swift target — it is content copied verbatim.

**Tuist targets NOT added**:

- `CodansCore`, `CodansIPC` — no skill-related code lives in these targets. Enforced by review and by `skill-orthogonality-check.sh`.

**Mirror repo (external artefact, one-time owner setup)**:

- `github.com/wanggang316/codans-skill` (Decision 12). Branch protection: `main` can only be written by the deploy key used in `mirror-skill.yml`. All commits come from that workflow. Tags are pushed alongside the sync commit.
