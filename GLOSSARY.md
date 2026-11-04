# Codans

## Workspace model

These terms define the Workspace group model. See the
[Workspace design](docs/design-docs/workspace.md) for its behavior.

**Workspace**: A collection of source projects with a default workspace group
and named workspace groups.

**Workspace group**: One set of member checkouts within a Workspace. Membership
refers to worktrees and does not change when a member switches branches.
_Avoid_: Git worktree when referring to the whole group.

**Default workspace group**: The group named `default` that references the
existing main checkout of each source project. Its members can use different
branches.

**Member checkout**: The working directory of one source project within a
workspace group.

## Agents View

These terms define what an Agents View row shows. See the
[AgentState design](docs/design-docs/active-agents-view.md).

**Agent runtime state**: The derived state of an agent in a pane: `idle`,
`working`, `blocked`, `done`, or `error`. It comes from the OSC 7501 program
status, or from the screen when the agent does not report.

**Agent activity text**: One line that tells what the agent is doing. It is the
OSC 7501 `message`, or the OSC 0/2 title that the agent set after it started
when there is no message. A title from before the agent started is not agent
activity text. It is for display only and does not change the runtime state.
_Avoid_: OSC status, because OSC 7501 also carries the runtime state.

## Sidebar

**Project order**: The user-curated sequence of Projects in the sidebar. It is
the order of `catalog.projects`; the user changes it by dragging a Project
block. See [ADR 0001](docs/adr/0001-project-order-is-manual-only.md).
_Avoid_: sort mode, join order, manual order.

**Host**: A machine on which Projects live: This Mac, or a record in the Host
list in Settings (Host address, Username, optional Port, optional Name,
optional Icon). Every
Project refers to exactly one Host. A Workspace and its member projects are on
one Host. See [ADR 0002](docs/adr/0002-sidebar-outline-with-host-level.md) and
[ADR 0003](docs/adr/0003-hosts-are-managed-records.md).
_Avoid_: server (except in "Server project"), SSH alias.

**This Mac**: The Host of all local Projects. The sidebar shows Host rows only
when at least one Project is on another Host.

## Code hosts

These terms define how codans relates a Worktree to a hosted review. See
[ADR 0004](docs/adr/0004-gitlab-support-through-glab.md).

**Code Host**: The service that hosts the `origin` remote of a source
repository and its reviews. codans supports GitHub and GitLab, on their
public sites and on self-managed instances. codans calls the CLI of each Code
Host (`gh`, `glab`).
A Code Host is not a Host: a Host is a machine on which Projects live. Do not
shorten Code Host to "host".
_Avoid_: Forge, Provider, Platform, host.

**Code Host alias**: A Settings entry that maps a remote host, as it appears
in an `origin` URL, to a Code Host kind and the API host that its CLI uses.
See [ADR 0005](docs/adr/0005-code-host-aliases.md).
_Avoid_: Host alias, because a Host is a machine.

**Pull Request**: A hosted review that asks to merge a source branch into a
target branch. It is the provider-neutral concept: a GitHub pull request and a
GitLab merge request are both Pull Requests. The UI shows the Code Host's own
label: "PR" for GitHub and "MR" for GitLab.
_Avoid_: Merge Request, MR, and Change Request as domain terms. Use Merge
Request and MR only in GitLab UI text and GitLab API code.
