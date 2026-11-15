# 0006. Project identity is its Host and its root path

Status: Accepted

## Context

A Project stores a root path. A Remote Project stores a path on its Host, not
on This Mac. Two machines often have the same layout and the same username, so
a local Project and a Remote Project can have the same root path string, for
example `/Users/me/dev/app` on This Mac and on a Host named `mini`.

codans compared Projects by root path only. Each lookup that took a path
matched every Project, on any Host:

- Add Project on This Mac found the Remote Project with the same path and
  selected it. The user could not add the local Project.
- The CLI `hierarchy.addProject` returned a conflict for the same reason.
- `codans open`, path targets in the CLI, Workspace membership, and the
  source-project match of a Workspace could resolve to a Remote Project.
- Open Remote Project had no duplicate check, so the same path on the same Host
  could be added two times.

[ADR 0003](0003-hosts-are-managed-records.md) gives each Host a record ID, and
every Project refers to exactly one Host.

## Decision

1. **Identity.** A Project is identified by its Host and its root path:
   `(hostID, rootPath)`. `hostID == nil` is This Mac. Two Projects on
   different Hosts can have the same root path. Two Projects on the same Host
   cannot. Hosts are compared by record ID, as ADR 0003 defines them: two
   records for the same machine are two Hosts.
2. **Path forms.** A local path is compared in its canonical form (symlinks
   resolved, standardized). A remote path is compared in its normalized form
   (string-only, no trailing slash). A remote path is never resolved against
   the local file system.
3. **One lookup.** The catalog has one lookup by `(hostID, path)`. All callers
   use it. No caller compares root paths directly.
4. **Local-path inputs match This Mac only.** A path that comes from this Mac
   (the folder picker, `hierarchy.addProject`, `codans open`, a CLI path
   target, Workspace membership, the source project of a Workspace) matches
   only Projects on This Mac. Workspaces and their members are local, so they
   never match a Remote Project.
5. **Duplicates.**
   - Open Remote Project: when the Host and the resolved path are already a
     Project, the sheet closes and that Project is selected, the same as Add
     Project on This Mac.
   - Edit Remote Project: a Host or path that makes the Project equal to another
     Project is an error in the sheet. The change is not applied.
   - Existing duplicates in a catalog are not merged or migrated.
6. **CLI Host field.**
   - Each command that takes a Project identifier has a `--host` option. Its
     value is a Host record ID (UUID) or `0` for This Mac. When it is not
     given, Projects are not filtered by Host. Any other value is an invalid
     parameter. An unknown Host ID is not found.
   - When a Project name matches more than one Project, the CLI returns a
     conflict that lists each match as `<project-id> host=<host-id|0>`.
   - When the Project is given by ID and `--host` does not match its Host,
     the CLI returns an error.
   - Every CLI and IPC output that shows a Project includes its `hostID`: the
     Host record ID, or `"0"` for This Mac.
   - `hierarchy.resolveAlias` takes an optional `hostID` with the same values.

## Reasons

- The path alone does not identify a Project once Projects live on more than
  one machine. The Host is part of where a Project is.
- One lookup keeps the rule in one place, so a new caller cannot compare paths
  without the Host.
- A local path from this Mac cannot refer to a directory on another machine,
  so a local-path lookup must not match a Remote Project.
- A Host ID does not change when the Host name or address changes, so scripts
  that pass `--host` keep working.
- `0` is one value for input and output. A script can copy the `hostID` of an
  output into `--host`. An empty value is not used, because an unset shell
  variable would then select This Mac without an error.

## Trade-offs

- A merge of existing duplicates is left to the user (remove one Project).
- The `hostID` output field is a string that holds a UUID or `"0"`.
- A name that matches Projects on two Hosts needs `--host` or a Project ID.

## Reconsider when

- Users need one Project that spans more than one Host.
- Hosts get an identity across machines (for example a synced Host list).
