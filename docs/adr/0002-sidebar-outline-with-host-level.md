# 0002. The sidebar is an NSOutlineView with a Host level

Status: Accepted

Supersedes in part: [ADR 0001](0001-project-order-is-manual-only.md),
decision 3 (how a Project drag is done) and decision 4 (where a drop can go).

## Context

[ADR 0001](0001-project-order-is-manual-only.md) makes the Project order the
`catalog.projects` array order and asks for a direct drag of a Project block.
The sidebar is a SwiftUI `List` in sidebar style. A prototype for ADR 0001
showed:

- `.draggable` / `.onDrag` on a row in `List(selection:)` starts a drag only
  once per app launch. A drawn indicator from row-level `onDrop` lags and stays
  after the drop.
- A `Section(isExpanded:)` per Project with `ForEach.onMove` gives the native
  block drag. But a Section header cannot be click-selected, and a Project shown
  as a plain row gets no Section gap.

The sidebar also gets a Host level: Projects are grouped by the machine they
live on. With Workspace groups, the tree then has up to five levels. SwiftUI
Sections cannot nest, and `List(children:)` / `OutlineGroup` do not support
`onMove`.

## Decision

1. **NSOutlineView.** The sidebar tree is an AppKit `NSOutlineView`. Row
   content can stay SwiftUI, hosted in each cell.
2. **Host level.** The top level is the **Host**: **This Mac** for local
   Projects, and one row per Host that has Projects. Hosts come from the Host
   list in Settings (see the [glossary](../../GLOSSARY.md)).
3. **Only This Mac → no Host level.** When every Project is on This Mac, the
   sidebar shows no Host rows. Projects are then the top level.
4. **Host order is fixed.** The user cannot drag Hosts.
5. **Project drag stays inside its Host.** The native outline drag moves a
   Project block. A drop is valid only between Projects of the same Host. Other
   drops show no indicator and are refused. The new order still goes to the
   `catalog.projects` array (ADR 0001, decision 1).
6. **A Workspace belongs to one Host.** Its member projects cannot be on
   different Hosts.

## Reasons

- `NSOutlineView` supports any tree depth, native group rows, native
  expand / collapse, native selection on every level, and a native drag whose
  drop target (parent item and child index) the code can validate. The Host
  rule in decision 5 is one check on the proposed parent.
- The SwiftUI forms each fail one requirement (see Context). A fully drawn
  `ScrollView` sidebar would lose native selection, keyboard navigation, and
  the native drag indicator.
- The diff file outline already uses `NSOutlineView`, so the app has a working
  pattern for it.

## Trade-offs

- The sidebar view moves from SwiftUI `List` to an outline data source and
  delegate. Selection, context menus, the ⌃1…⌃0 slots, scroll-to-selection,
  worktree segment drag, and accessibility must be wired again.
- Until the migration lands, Project drag (ticket #320) cannot ship.

## Reconsider when

- SwiftUI `List` gets nested Sections or `onMove` for hierarchical content.
