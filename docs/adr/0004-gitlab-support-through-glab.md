# 0004. GitLab support through glab

Status: Accepted. Superseded in part by [ADR 0005](0005-code-host-aliases.md): item 2 (the Project settings step) and item 10 (the Project Code Host choice).

## Context

codans shows the Pull Request of each Worktree in the sidebar badge, the
popover, the status bar, and the worktree header. It also runs write actions
(merge, close, mark ready, rerun failed jobs) and opens the Pull Request or the
Project on the Code Host. Only GitHub supports this, through the `gh` CLI. See
[Code Host Integration](../design-docs/code-host-integration.md) (formerly GitHub Integration).

`RemoteInfo` does not check the host, so the app sends a GitLab `origin` to
`gh`, and the fetch fails. `RemoteInfo` also keeps only the first two path
segments of the remote, which is not sufficient for GitLab nested groups. Many
GitLab users run a self-managed instance.

## Decision

1. **Same surface.** GitLab gets every Pull Request surface that GitHub has:
   badge, popover, status bar, worktree header, write actions, "Open on Code
   Host" commands, the Diff Viewer target ref, and Settings. codans adds no
   GitLab-only feature (issues, comment threads, pipeline dashboards).
2. **Hosts.** codans supports gitlab.com and self-managed GitLab instances.
   It resolves the Code Host of a source repository from its `origin` host in
   this order:
   - `github.com` or a host that `gh` is logged in to: GitHub.
   - `gitlab.com` or a host that `glab` is logged in to: GitLab.
   - A Code Host that the user sets in the Project settings.
   - Otherwise: no Code Host. codans shows no badge and no error.
3. **Transport.** codans calls the `glab` CLI (`glab api graphql` for reads).
   codans sends no HTTP request itself and stores or forwards no token. This is
   the same rule as for `gh`.
4. **Terms.** "Code Host" names GitHub and GitLab. "Pull Request" is the
   provider-neutral concept; the UI label is "PR" for GitHub and "MR" for
   GitLab (see [GLOSSARY](../../GLOSSARY.md)).
5. **One Code Host interface.** All Code Host behavior is behind one interface
   with one implementation per Code Host (GitHub, GitLab). Fetch scheduling,
   cache, invalidation, the reducer, and the views use only this interface and
   the provider-neutral model. They do not branch on the Code Host, except to
   select the UI label and the implementation. Modules named after GitHub that
   hold shared behavior move into this Code Host layer.
6. **GitLab merge.** The GitLab merge method (merge commit, semi-linear,
   fast-forward) is the project setting; codans does not override it. The
   popover offers "Merge" and "Squash and merge". "Squash and merge" is
   disabled, with the reason, when the project does not allow squash. The
   default merge strategy maps `mergeCommit` and `rebase` to Merge, and
   `squash` to Squash and merge. codans does not offer auto-merge.
7. **GitLab CI.** The jobs of the head pipeline map to check results. A failed
   job with `allow_failure` is neutral. A manual job that did not run is
   skipped. "Rerun failed jobs" retries the pipeline, which retries only its
   failed jobs.
8. **GitLab review decision.** All approval rules met: approved. Approvals still
   required: review required. A reviewer requested changes (on instances that
   report it): changes requested. No approval rules: no review decision.
9. **GitLab fork merge requests.** The fork filter of GitHub applies, with the
   source project path in place of the head repository owner.
10. **Settings.** One "Code Hosts" settings pane shows the availability of
    `gh` and `glab`. The default merge strategy and the post-merge Worktree
    action apply to all Code Hosts. Project settings have a "Code Host" choice
    (Auto, GitHub, GitLab).
11. **Interface shape.** Each Code Host implements one protocol: availability,
    a batched Pull Request read for a repository and its branches, the write
    actions, and web URLs for the repository and the Pull Request. Capability
    differences are data on the Pull Request snapshot (for example, the merge
    options with their enabled state and reason, and whether failed checks can
    rerun). The protocol has no optional methods.
12. **Identity.** A Code Host repository is its kind, host, and full path. The
    full path keeps every segment, because GitLab projects can be in nested
    groups (`group/sub/repo`). Write actions take a Pull Request reference
    (repository and number; the GitLab `iid`). They do not resolve the
    repository from the subprocess working directory.
13. **Resolution and selection.** A resolver applies the order in item 2. The
    reducer keeps the result per fetch unit. One TCA client selects the
    implementation by Code Host kind. One reducer owns the fetch lifecycle for
    all Code Hosts.
14. **Provider-neutral model.** Availability, errors, and merge state are
    provider-neutral types. Errors that depend on the CLI carry the Code Host
    kind. Merge state is clean, conflicted, behind, blocked, draft, or unknown,
    with an optional reason text from the Code Host. Only the decoding layer of
    each implementation knows the wire values of its Code Host. A cached
    snapshot that does not decode is discarded; the next fetch replaces it.
15. **Missing CLI.** When a fetch unit resolves to GitLab and `glab` is missing
    or not logged in, the badge position shows the same actionable message as
    for a missing `gh`.
16. **Mixed Workspaces.** Each fetch unit resolves its own Code Host, so one
    Workspace can have GitHub and GitLab members.

## Reasons

- Users of both Code Hosts run agents in Worktrees and need the same review
  status. A partial GitLab surface makes the UI behave differently by host.
- Self-managed instances are the main GitLab use case, so gitlab.com alone does
  not cover most users.
- A CLI keeps authentication, token storage, and host configuration out of
  codans. The GitHub design rejected in-app OAuth for the same reason.
- GitLab GraphQL can query many source branches of one project in one request
  (`mergeRequests(sourceBranches:)`), so one fetch per fetch unit stays
  possible.
- "Pull Request" is the widely known term. Keeping it avoids a rename of the
  shared model types.
- One interface keeps Code Host differences in one place. A third Code Host
  then needs a new implementation, not changes in the reducer or the views.
- An explicit Pull Request reference does not depend on the working directory,
  so members of one Workspace on different Code Hosts cannot mix up their
  repositories.
- The GitLab project owns its merge method. A client that overrides it breaks
  the rules of the project.
- Without the CI mapping, an optional failed job turns the badge red, and a
  manual job keeps it in progress for all time.

## Trade-offs

- GitLab users must install `glab` and run `glab auth login`. `glab` is less
  common than `gh`.
- GitLab code paths use the type names `PullRequest…` for merge requests.
- GitLab cannot use the `rebase` strategy as GitHub does.
- Manual jobs that did not run do not show as pending, so the badge does not
  show an open manual deployment.
- Instances that do not report requested changes show fewer review states.
- One default merge strategy applies to both Code Hosts.
- Settings has a "Hosts" pane (machines, ADR 0003) and a "Code Hosts" pane.
  The names are close, so the pane text must keep the two concepts apart.
- Host detection needs an auth-status probe of both CLIs and a Project setting
  for hosts that neither CLI knows.

## Reconsider when

- A third Code Host (for example, Gitea or Bitbucket) is requested.
- `glab` cannot provide a needed read or write action.
- Users need GitLab support without installing `glab`.
