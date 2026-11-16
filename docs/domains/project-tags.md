# Project Tags

A Tag is a label that the user puts on Projects to group them across the hierarchy. A Project can have many Tags, and a Tag can be on many Projects. A Tag does not own Worktrees, Tabs, or Panes, and it has no selection or session state.

Availability: Hidden for all user entry points. The model, the mutations, and the socket methods are implemented, and every catalog carries the Tag fields. There is no mounted UI to create, assign, or filter by Tags, and the CLI has no tag verbs. The only visible trace is the `tags` row of `codans project show`, which prints the Tag IDs of a Project.

## Scope and ownership

This page owns the Tag model, the mutation rules, and the Tag filter. Neighbor topics:

- The sidebar, its category filter bar, and its footer: [Main Window](main-window.md).
- The catalog file, its versions, and the save path: [Architecture › Persistence](../architecture.md#persistence).
- CLI verbs and the `current` pronoun: [CLI](cli.md).

## Model

```
Catalog
 ├─ tags: [Tag]              Tag = id (TagID) + name + color
 ├─ activeTagFilter          all | tags(Set<TagID>) | untagged
 └─ projects: [Project]
      └─ tagIDs: Set<TagID>  references into Catalog.tags
```

- The `TagID` (a UUID) is the identity. The name is only a display string: names can repeat, and rename does not touch any Project.
- The color is one of a fixed palette of seven (`TagColor`: red, orange, yellow, green, blue, purple, grey). Arbitrary colors are not supported.
- Tags apply to Projects only. There are no Tags on Worktrees, no nested Tags, and no saved filters.
- `HierarchyManager` holds the Tags in its catalog, like the rest of the hierarchy. Views read the observable catalog and keep no copy.

### Stored form

All three fields are optional on decode, so a catalog without them decodes as "no Tags, filter `.all`, every Project untagged". On encode, `Project.tagIDs` is omitted when empty and `activeTagFilter` is omitted when `.all`. Sets are written as arrays sorted by UUID, so `catalog.json` diffs stay stable; the order has no meaning. The filter is written as a tagged object (`kind`, plus `tagIDs` for `tags`).

## Mutation rules

All mutations go through `HierarchyManager`. A mutation that changes nothing (unknown ID, same value) does not schedule a save; one that changes the catalog schedules the usual debounced save.

- **Create** trims the name. An empty name appends nothing but still returns a new `TagID` that refers to no Tag. A caller must check the name before it treats the result as a created Tag. The socket method has the same behavior.
- **Rename** trims the name and ignores an empty name. **Rename** and **Recolor** ignore an unknown ID in the manager; the socket methods return `notFound` for it, and refuse a color string outside the palette.
- **Delete** removes the Tag, removes its ID from every Project, and removes it from the active filter. A `tags` filter that becomes empty turns into `.all`. Delete changes classification only: Project directories, Worktrees, Tabs, and Panes do not change.
- **Assign** (`setProjectTags`) replaces the whole Tag set of one Project. It does not check that each ID exists in `Catalog.tags`. The socket method checks only that the Project exists.

Rule for a new caller: send only IDs from `Catalog.tags`. An unknown ID in `tagIDs` or in the filter is kept and saved; delete is the only path that removes IDs.

## Tag filter

The filter is catalog-wide and saved. `tags(set)` keeps a Project that has at least one Tag of the set (OR). `untagged` keeps Projects with no Tags. `setActiveTagFilter` turns an empty `tags` set into `.all`, and the sidebar code also reads an empty set as `.all`.

The sidebar applies the Tag filter first and the category filter (All, Remote, Workspace, PR, Unread) second, so the result is the intersection. A Tag filter that is not `.all` counts as "filtered" for the Host level of the sidebar, like a category filter.

The chip logic of the hidden footer control: a tap on a Tag adds it to or removes it from the set, and removing the last Tag gives `.all`.

## Socket methods

The `hierarchy` namespace has `listTags`, `createTag`, `renameTag`, `recolorTag`, `removeTag`, `setProjectTags`, and `setActiveTagFilter`. All are routed by the app. `hierarchy.listProjects` accepts at most one of `tag` and `untagged`. Alias resolution has a `tag` kind that matches a Tag name case-insensitively; `current` never resolves for it.

No CLI verb sends these methods. `CODANS_TAG_ID` is in `CodansEnvironment.Key`, and the alias resolver reads it for the `tag` kind, but no CLI argument uses that kind, so the variable has no effect.

## Hidden UI

These parts exist and are wired, but no view on screen mounts their entry point:

- The Tag filter button of the sidebar footer, with its All, per-Tag, and Untagged list.
- The Tags submenu of the Project context menu (assign a Tag, and "Edit Tags…").
- The Tag manager sheet (create, rename, recolor, confirmed delete). The root feature presents it on `openTagManager`, but only the two hidden controls above send that action.

## Traps

- A saved filter still applies with its control hidden. A catalog that has a `tags` or `untagged` filter hides Projects, and the UI has no way to clear it. Only `hierarchy.setActiveTagFilter` with `{"filter": {"kind": "all"}}` over the socket, or an offline edit of the catalog with the app quit, clears it.
- A filter that holds only unknown IDs hides every Project.
- To show a hidden control again, mount it at its marked place in `TagChipFooter` or the Project context menu of `HierarchySidebarView`; the reducer and the root routing need no change.
