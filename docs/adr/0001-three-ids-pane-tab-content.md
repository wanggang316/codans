---
status: accepted
---

# Three ids: PaneID, TabID, ContentID

A Worktree layout is a split tree of Panes; a Pane holds Tabs; a Tab holds one Content. Each level has its own id, and the session identity is the ContentID: zmx session names, agent state, notifications, command queues, and `CODANS_CONTENT_ID` all key on it. TabID carries only chip attributes and strip position; PaneID carries only layout and focus. When the catalog migrates to v5 (from v3 or v4), each session's UUID becomes its ContentID unchanged, and TabID / PaneID are freshly generated.

## Considered options

- One id for Tab and Content. Saves a field, but a Content that moves between Tabs or is replaced inside a Tab would lose its ledger (sessions, agent state, notifications).
- Keep "Pane" as the session name and call the container "Card". Keeps old CLI spellings, but inverts the pane / tab usage of Xcode and comparable terminal products, and makes the UI word "tab" and the model word "Pane" denote the same object.

## Consequences

- `CODANS_PANE_ID` means the Pane; `CODANS_TAB_ID` means the Tab; `CODANS_CONTENT_ID` means the session.
- Every CLI id position accepts any of the three ids and resolves to the level the verb needs.
