# Codans

## Workspace model

These terms define the planned Workspace group model. See the
[Workspace design](docs/design-docs/workspace.md) for availability and behavior.

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
