# 0003. Hosts are managed records in the catalog

Status: Accepted

## Context

[ADR 0002](0002-sidebar-outline-with-host-level.md) groups the sidebar by
**Host**. Each Remote Project stores its own `RemoteHost { alias, username?,
port? }`. There is no shared host entity. `saved-server-hosts.json` is only a
recent-hosts list for the Open Remote Project sheet. A sidebar group needs a
stable identity, and a change to a host address must apply to all its
Projects.

## Decision

1. **Identity.** A Host is a record with its own ID and these fields:
   - **Host**: a domain name, an SSH config alias, or an IP address.
   - **Username**.
   - **Port**: optional, default 22.
   - **Name**: optional display name. The sidebar shows Name, or Host when
     Name is empty.

   Two records with the same Host, Username, and Port are not allowed. The same
   machine with two usernames is two Hosts. codans does not merge Hosts that
   point to the same machine.
2. **Projects refer to a Host by ID.** A change to a Host record applies to all
   its Projects.
3. **Settings owns the Host list.** A Hosts page in Settings adds, edits, and
   deletes Hosts.
4. **Open Remote Project picks a Host.** The sheet has a Host picker with a
   "New Host…" entry. A Host made from "New Host…" always goes to the Host
   list, with the same validation as the Settings page. There is no temporary
   Host. When the fields are equal to an existing Host, the sheet uses that
   Host. A Project's Edit Remote Project changes its Host choice and its path, not
   the Host fields.
5. **No delete of a Host in use.** Delete is disabled while Projects refer to
   the Host, and the page shows how many.
6. **Order.** This Mac is first. Other Hosts follow the Host list order, which
   is the order of addition. Neither the sidebar nor Settings reorders Hosts.
7. **Host row.** A Host row is not selectable. A click expands or collapses
   it, and the expansion state persists. The context menu has
   "Open Remote Project on This Host…" and "Edit Host…"; on This Mac it has
   "Open Project…". A Host with no Projects has no sidebar row.
8. **Migration.** On upgrade, each distinct (Host, Username, Port) of the
   existing Remote Projects becomes a Host record, and those Projects refer to
   it. The recent-hosts list is not migrated; the Host list replaces it.
9. **Storage.** The Host list is in `catalog.json` (`hosts`), beside the
   Projects that refer to it, with `HierarchyManager` as its single writer.
   The Settings page reads and writes it through `HierarchyClient`.
10. **CLI and IPC.** `codans tree` and the describe output show the Host (ID
    and display name) of each Project. The CLI has no command to add, edit, or
    delete Hosts.
11. **No Host connection state.** A Host row shows no connection status. Each
    Project shows its own connection error, as before.

## Reasons

- One record per Host keeps host data in one place, so an address change is one
  edit.
- An ID reference does not change when the address or display name changes.
- The catalog has one writer and holds both sides of the reference, so a
  Project cannot point at a Host that the same file does not hold.
- Blocking delete of a Host in use keeps every reference valid and prevents a
  cascade delete of many Projects.

## Trade-offs

- Host is configuration but is not in `settings.json`.
- Recent hosts with no Project are lost at migration.
- Users cannot put a frequently used Host first.
- A Host used once stays in the Host list until the user deletes it.
- Scripts cannot manage Hosts.
- When a Host is down, each of its Projects reports its own error.

## Reconsider when

- Users need Hosts shared across machines or synced (a settings-level store
  may fit better).
- Users ask to reorder Hosts.
