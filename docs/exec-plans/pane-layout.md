# Pane Layout Execution Plan

Design: [docs/design-docs/pane-layout.md](../design-docs/pane-layout.md). Glossary: [CONTEXT.md](../../CONTEXT.md). Decisions: ADR-0001, ADR-0002.

## Objective

Ship P1 of the pane layout on `feat/card-pane`: a Worktree is a split tree of Panes, each Pane holds a strip of Tabs, each Tab holds one Content. Catalog v4 with a one-shot v3 → v4 migration, a content runtime outside `HierarchyManager`, one capsule tab strip per Pane, and the renamed CLI / IPC / environment surface. One PR; every commit builds.

## Scope

- In: CodansCore model + migration, content runtime, per-Pane strip, keyboard routing, close confirmation setting, CLI / IPC / env rename, settings key migration, forward-version read-only screen, lossy-decode reaper gate, docs and skill rewrite, CHANGELOG Breaking section.
- Out (P2): tab-chip drag, edge-split drop zones, zoom exit control.
- Out (P3, separate design each): hover-to-focus, unfocused dim, window mode, additional content kinds.

## Sequence

Commits in this order; each is a buildable, self-describing step.

1. **Model.** Add `Pane`, `Tab`, `ContentSnapshot`, `ContentState`, `TerminalContentState`, `ContentID` to CodansCore; `Worktree` gains `splitTree`, `panes`, `focusedPaneID`; remove the old `Tab` / `Pane` types. Tests first: invariants (`isConsistent`), tolerant decode with loss count, omit-when-default encoding.
2. **Migration.** `Catalog.currentVersion = 4`; `CatalogMigrationV3ToV4` with the six rules from the design doc; `CatalogStore.load` backs up v3 via `StoreBackup`, writes v4 immediately, and returns a read-only state for a newer version or a failed migration. Tests: fixture v3 catalogs (single tab, multi-tab, split tab, empty tab, zoomed, nil selection, malformed record).
3. **Runtime.** `Runtime/Content/`: `TabContent`, `ContentRuntime`, `TabChrome`, `ContentGeometry`, `TerminalContent` (wraps the `TerminalEngine` surface lifecycle). `HierarchyManager` drops `runningPanes`, `commandBusyPanes`, `lastFocusedPaneByTab`; its mutation API becomes Pane / Tab verbs. `AgentStateStore`, `SurfaceReclaimPolicy`, inbox key on ContentID. Reaper and unread sweeps gated on decode loss and read-only state.
4. **UI.** `SplitViewportView` renders Panes; `PaneView` = strip + content host; `TabBarView` becomes per-Pane with active / inactive styling and the narrow-width accessory rule; `TabHUD`; keyboard `CommandID` routing to the focused Pane; close confirmation (`busy | always | never`); empty-worktree state. Screenshot check on an isolated instance.
5. **CLI / IPC.** `codans tab` / `codans pane` verb layout, three-id token resolution, `p<n>` / `t<n>` handles, hard errors for moved verbs, `broadcast` scope rename, `hierarchy.describe` shapes, handshake version bump, pane environment (`CODANS_PANE_ID` / `CODANS_TAB_ID` / `CODANS_CONTENT_ID`), settings key migration.
6. **Docs.** product-spec C2 and glossary, architecture.md, cli.md, main-window.md Tab Bar section (pointer to pane-layout.md), `skills/codans-cli/SKILL.md`, design-docs index, CHANGELOG Breaking section.

## Verification

- CodansCore: model and migration suites green before the runtime commit lands.
- `HierarchyManagerTests`: Pane never empty, focus consistency, selection validity after every batch close.
- `xcodebuild test` per touched suite, named by suite, test counts checked.
- CLI black-box regression harness (`.claude/skills/self-verify/cli-regression/harness.sh`) over every verb on an isolated Debug instance.
- GUI: isolated instance with private `CODANS_CONFIG_DIR` / `CODANS_STATE_DIR` / `CODANS_SOCKET_PATH` / `CODANS_CACHE_DIR`; screenshots of focused / unfocused strips, narrow Pane, zoom, empty Worktree, and a migrated v3 fixture.
- `swift format` + `swiftlint` on changed files only.

## Acceptance

- A v3 catalog with N tabs opens as one Pane layout with all sessions reattached (same zmx names), titles and colors on the first Tab of each former tab.
- A catalog stamped with a version above the build shows the upgrade screen; no file is moved or written; no zmx session is killed.
- `codans tab send`, `codans pane split`, `--pane <tab-id>` and `--tab <content-id>` resolve as specified; `codans pane send` exits non-zero with the new location.
- ⌘T / ⌘W / ⌘1–9 act on the focused Pane's strip; splitRight / splitDown create a Pane; zoom hides the other Panes.
- Closing the last Tab closes its Pane; the Worktree shows the empty state at zero Panes.

## Status

Planned. No code yet.
