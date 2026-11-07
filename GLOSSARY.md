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
_Avoid_: server, SSH alias.

**Remote Project**: A Project whose root is on a Host other than This Mac.
codans reaches it over SSH. The Add Project menu opens one with "Open Remote
Project…", and the Project's menu changes its Host and path with "Edit Remote
Project…". Its `ProjectKind` is `.remote`; the CLI JSON writes the kind as
`server`. See [Remote Projects over SSH](docs/design-docs/remote-ssh-projects.md).
_Avoid_: Server project, remote connection, Connect to Server.

**This Mac**: The Host of all local Projects. The sidebar shows Host rows only
when at least one Project is on another Host. The CLI writes it as Host ID `0`.

**Project identity**: A Project is identified by its Host and its root path.
Two Projects on different Hosts can have the same root path; two Projects on
the same Host cannot. A path from this Mac matches only Projects on This Mac.
See [ADR 0006](docs/adr/0006-project-identity-is-host-and-path.md).
_Avoid_: identifying a Project by its name or by its path alone.

## Git platforms

These terms define how codans relates a Worktree to a hosted review. See
[ADR 0004](docs/adr/0004-gitlab-support-through-glab.md).

**Git Platform**: The service that hosts the `origin` remote of a source
repository and its reviews. codans supports GitHub and GitLab, on their
public sites and on self-managed instances. codans calls the CLI of each Git
Platform (`gh`, `glab`).
A Git Platform is not a Host: a Host is a machine on which Projects live. Do not
shorten Git Platform to "host" or "platform".
_Avoid_: Code Host, Forge, Provider, host.

**Git Platform alias**: A Settings entry that maps a remote host, as it appears
in an `origin` URL, to a Git Platform kind and the API host that its CLI uses.
See [ADR 0005](docs/adr/0005-git-platform-aliases.md).
_Avoid_: Host alias, because a Host is a machine.

**Pull Request**: A hosted review that asks to merge a source branch into a
target branch. It is the provider-neutral concept: a GitHub pull request and a
GitLab merge request are both Pull Requests. The UI shows the Git Platform's own
label: "PR" for GitHub and "MR" for GitLab.
_Avoid_: Merge Request, MR, and Change Request as domain terms. Use Merge
Request and MR only in GitLab UI text and GitLab API code.
