# Project Tags and Single Main Window

**Availability:** Single main window available; Tag storage and mutation APIs implemented; Tag filter and assignment UI hidden; Tag CLI commands unavailable.

## Scope

Codans has one main window and a separate Settings window. Its hierarchy is
`Catalog → Project → Worktree → Tab → Pane`. Tags classify Projects across
that hierarchy without owning their worktrees or terminal sessions.

The authoritative structural state is `HierarchyManager.catalog`. Selection
belongs to `Catalog.selectedProjectID`, `Project.selectedWorktreeID`, and
`Worktree.selectedTabID`. A Tag has no independent selection or session state.

## Data Model

| Type / field | Contract |
|---|---|
| `Tag.id` | Stable UUID identity; names are not identifiers |
| `Tag.name` | Mutable display name; duplicate names are allowed |
| `Tag.color` | Fixed palette: red, orange, yellow, green, blue, purple, grey |
| `Project.tagIDs` | Set of memberships, encoded as a sorted array |
| `Catalog.tags` | Tag definitions |
| `Catalog.activeTagFilter` | Catalog-wide filter, default `.all` |
| `TagFilter.all` | Include all Projects |
| `TagFilter.tags(Set<TagID>)` | Include Projects sharing at least one selected Tag (OR) |
| `TagFilter.untagged` | Include Projects with no Tag memberships |

`TagFilter` uses a tagged Codable representation (`kind`, optional `tagIDs`).
An empty `.tags` set is normalized to `.all` by
`HierarchyManager.setActiveTagFilter`. The decoder itself preserves the
encoded filter case. Sorted UUID arrays make persisted membership order
stable without making order part of the classification semantics.

Source: [Tag.swift](../../apps/mac/CodansCore/Tag.swift),
[Project.swift](../../apps/mac/CodansCore/Project.swift), and
[Catalog.swift](../../apps/mac/CodansCore/Catalog.swift).

## Mutation and Persistence

`HierarchyManager` owns Tag mutations; `HierarchyClient` exposes them to app
features. Views read the observable catalog rather than maintaining a second
copy of Tags or memberships.

- `createTag` trims the name and appends only non-empty names. An empty name
  returns an unregistered ID; callers must validate input before treating the
  result as a created Tag.
- `renameTag` trims the name and ignores empty names, unknown IDs, or unchanged
  values. `recolorTag` ignores unknown IDs and unchanged values.
- `removeTag` removes the definition, strips the ID from every Project, and
  removes it from the active filter. An empty remaining filter becomes `.all`.
  Project directories, worktrees, tabs, and panes are unaffected.
- `setProjectTags` replaces membership for an existing Project. It does not
  validate each supplied Tag ID; callers are responsible for selecting valid
  definitions.
- Effective mutations schedule a catalog save through `CatalogStore`.
  `CatalogStore` debounces writes by 500 ms and supports a synchronous flush.

### Catalog format

`Catalog.currentVersion` is **3**. `Catalog.init(from:)` requires that exact
version and throws `DecodingIssue.unsupportedVersion` for any other value.
There is no v1/v2 catalog conversion path. Missing optional v3 fields have
field-specific defaults; this is not compatibility with another schema version.

`AtomicFileStore.read` returns nil for a missing file and throws on decode or
I/O errors. `CatalogStore.load` propagates those errors. App bootstrap uses an
empty catalog when loading fails. This path does not automatically back up or
convert an unsupported catalog; a subsequent save can replace the file with
the in-memory catalog. Configuration recovery therefore requires a preserved
copy of the source file before launching a build that cannot decode it.

Writes use a sibling temporary file, `fsync`, and atomic rename. A failed write
leaves the previous destination intact. File-write atomicity does not provide
schema conversion or cross-file migration guarantees.

Source: [HierarchyManager.swift](../../apps/mac/codans/Runtime/HierarchyManager.swift),
[CatalogStore.swift](../../apps/mac/codans/Runtime/CatalogStore.swift),
[AtomicFileStore.swift](../../apps/mac/CodansCore/AtomicFileStore.swift), and
[CodansApp.swift](../../apps/mac/codans/App/CodansApp.swift).

## Sidebar and Tag Management

The sidebar applies `Catalog.activeTagFilter` to its Project list. During
manual reordering it displays the full Project set so movement indices refer
to the same array that the reorder operation mutates.

The footer's Tag filter control and the Project context menu's `ProjectTagsMenu`
are hidden. The footer exposes reordering, Agents View, and refresh controls.
Stored filters still affect Project visibility even though the filter button
is hidden.

`TagFilterList` and the filter actions support All, per-Tag selection, and
Untagged. The `TagManagerFeature` sheet supports creation, rename, recolor,
and confirmed removal. Its removal payload captures the Tag name and affected
Project count at request time so the confirmation text stays consistent.
These components and their app routing exist, but the hidden sidebar controls
do not provide a visible entry point to them.

Source: [HierarchySidebarView.swift](../../apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift),
[TagChipFooter.swift](../../apps/mac/codans/App/Features/HierarchySidebar/TagChipFooter.swift),
and [TagManagerFeature.swift](../../apps/mac/codans/App/Features/TagManager/TagManagerFeature.swift).

## IPC and CLI

Tag operations use the hierarchy namespace:

- `hierarchy.createTag`
- `hierarchy.renameTag`
- `hierarchy.recolorTag`
- `hierarchy.removeTag`
- `hierarchy.setProjectTags`
- `hierarchy.setActiveTagFilter`

The callable CLI does not register `codans tag` or `codans project tag`.
RPC method availability does not imply a matching command-line wrapper.
The IPC framing and version handshake are defined in [CLI](cli.md#wire-协议).

Source: [Method.swift](../../apps/mac/CodansIPC/Method.swift) and
[CodansCLI.swift](../../apps/mac/codans-cli/CodansCLI.swift).

## Single-Window Behavior

The main scene uses `Window("Codans", id: CodansApp.mainWindowID)`. Its scene
identity provides a single main window; Settings has its own window identity.
Closing the last window does not terminate the app
(`applicationShouldTerminateAfterLastWindowClosed` returns false).

The default **Command-W** binding invokes Close Tab in the main window. In
Settings it closes that Settings window. It is not a main-window-hide shortcut.

Quit confirmation and terminal disposition are independent settings:

- `quitConfirmation`: `never`, `always`, or `auto`; `auto` asks only when a
  live Pane is busy: a foreground command, OSC 9;4 progress, or an agent in
  `working` / `blocked` state. Idle shells and idle / finished agents do not
  trigger the dialog.
- `quitAction`: keep sessions running or snapshot them on exit. The confirmation
  dialog also offers cancellation.
- Session disposition finishes asynchronously before app termination. A
  re-entrancy guard prevents duplicate detach/snapshot passes.

See [Architecture: Session lifecycle](../architecture.md#session-lifecycle-quit-snapshot--launch-restore)
for snapshot and reattachment contracts. Keyboard defaults and user overrides
belong to [Keyboard Shortcuts](keyboard-shortcuts.md), not the Tag model.

Source: [CodansApp.swift](../../apps/mac/codans/App/CodansApp.swift) and
[MainWindowCommands.swift](../../apps/mac/codans/App/Commands/MainWindowCommands.swift).

## Design Constraints

- Stable Tag IDs keep rename and recolor independent of Project membership.
- Labels support multiple classifications per Project without adding another
  level of ownership or another selection-restoration system.
- Tag deletion changes classification only; it must not delete Project data.
- A fixed color enum gives persistence a bounded vocabulary. Arbitrary hex
  colors, nested Tags, saved filters, and Tags on Worktrees are unsupported.
- One main-window identity avoids competing owners of the same terminal
  surfaces and catalog selection.

## Test Sources

- [TagTests.swift](../../apps/mac/CodansCoreTests/TagTests.swift): Codable shape,
  color vocabulary, and filter representation.
- [HierarchyManagerTagTests.swift](../../apps/mac/codans/Tests/HierarchyManagerTagTests.swift):
  mutation, deletion cascade, and filter normalization.
- [CatalogCodableTests.swift](../../apps/mac/CodansCoreTests/CatalogCodableTests.swift):
  catalog schema and unsupported-version behavior.
