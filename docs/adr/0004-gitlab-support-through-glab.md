# 0004. GitLab support through glab

Status: Accepted. Superseded in part by [ADR 0005](0005-git-platform-aliases.md): item 2 (the Project settings step) and item 10 (the Project Git Platform choice). Item 2 amended 2026-11: the host-name step, the `glab` config file, and cache invalidation. Amended 2026-11-08: item 17 (merge only the head commit the user saw).

## Context

codans shows the Pull Request of each Worktree in the sidebar badge, the
popover, the status bar, and the worktree header. It also runs write actions
(merge, close, mark ready, rerun failed jobs) and opens the Pull Request or the
Project on the Git Platform. Only GitHub supports this, through the `gh` CLI. See
[Git Platform Integration](../design-docs/git-platform-integration.md) (formerly GitHub Integration).

`RemoteInfo` does not check the host, so the app sends a GitLab `origin` to
`gh`, and the fetch fails. `RemoteInfo` also keeps only the first two path
segments of the remote, which is not sufficient for GitLab nested groups. Many
GitLab users run a self-managed instance.

## Decision

1. **Same surface.** GitLab gets every Pull Request surface that GitHub has:
   badge, popover, status bar, worktree header, write actions, "Open on Git
   Platform" commands, the Diff Viewer target ref, and Settings. codans adds no
   GitLab-only feature (issues, comment threads, pipeline dashboards).
2. **Hosts.** codans supports gitlab.com and self-managed GitLab instances.
   It resolves the Git Platform of a source repository from its `origin` host in
   this order (amended 2026-11; the alias and `ssh -G` steps come from
   [ADR 0005](0005-git-platform-aliases.md) item 3):
   - A Git Platform alias for the host: its kind and API host.
   - `github.com` or a host that `gh` is logged in to: GitHub.
   - `gitlab.com` or a host that `glab` is logged in to: GitLab. codans reads
     these hosts from the local `glab` config file (`config.yml` in
     `GLAB_CONFIG_DIR`, the XDG config home, `~/.config/glab-cli`, or
     `~/Library/Application Support/glab-cli`). It reads only the host names,
     whether each has a token, and the API protocol. This needs no network
     and works with every `glab` version.
   - For an SSH remote: the `ssh -G` HostName, matched to one of those hosts.
   - The host name: a host that contains `gitlab` is GitLab, and one that
     contains `github` is GitHub (`gitlab.corp.example.com`). For an SSH remote
     the name is its `ssh -G` HostName without the SSH port. A name that
     contains both resolves to no Git Platform. When the CLI of that kind is
     missing or not logged in to the host, the badge position shows the
     install or `auth login` message (item 15). An alias corrects a wrong guess.
   - Otherwise: no Git Platform. codans shows no badge and no error.

   The cached CLI paths and logged-in hosts are dropped when a `gh` or `glab`
   command finishes in a pane, and by the Settings "Re-check". A missing CLI is
   not cached. Thus an install or an `auth login` in a pane shows the badge
   without a Re-check.
3. **Transport.** codans calls the `glab` CLI (`glab api graphql` for reads).
   codans sends no HTTP request itself and stores or forwards no token. This is
   the same rule as for `gh`.
4. **Terms.** "Git Platform" names GitHub and GitLab. "Pull Request" is the
   provider-neutral concept; the UI label is "PR" for GitHub and "MR" for
   GitLab (see [GLOSSARY](../../GLOSSARY.md)).
5. **One Git Platform interface.** All Git Platform behavior is behind one interface
   with one implementation per Git Platform (GitHub, GitLab). Fetch scheduling,
   cache, invalidation, the reducer, and the views use only this interface and
   the provider-neutral model. They do not branch on the Git Platform, except to
   select the UI label and the implementation. Modules named after GitHub that
   hold shared behavior move into this Git Platform layer.
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
10. **Settings.** One "Git Platforms" settings pane shows the availability of
    `gh` and `glab`. The default merge strategy and the post-merge Worktree
    action apply to all Git Platforms. Project settings have a "Git Platform" choice
    (Auto, GitHub, GitLab).
11. **Interface shape.** Each Git Platform implements one protocol: availability,
    a batched Pull Request read for a repository and its branches, the write
    actions, and web URLs for the repository and the Pull Request. Capability
    differences are data on the Pull Request snapshot (for example, the merge
    options with their enabled state and reason, and whether failed checks can
    rerun). The protocol has no optional methods.
12. **Identity.** A Git Platform repository is its kind, host, and full path. The
    full path keeps every segment, because GitLab projects can be in nested
    groups (`group/sub/repo`). Write actions take a Pull Request reference
    (repository and number; the GitLab `iid`). They do not resolve the
    repository from the subprocess working directory.
13. **Resolution and selection.** A resolver applies the order in item 2. The
    reducer keeps the result per fetch unit. One TCA client selects the
    implementation by Git Platform kind. One reducer owns the fetch lifecycle for
    all Git Platforms.
14. **Provider-neutral model.** Availability, errors, and merge state are
    provider-neutral types. Errors that depend on the CLI carry the Git Platform
    kind. Merge state is clean, conflicted, behind, blocked, draft, or unknown,
    with an optional reason text from the Git Platform. Only the decoding layer of
    each implementation knows the wire values of its Git Platform. A cached
    snapshot that does not decode is discarded; the next fetch replaces it.
15. **Missing CLI.** When a fetch unit resolves to GitLab and `glab` is missing
    or not logged in, the badge position shows the same actionable message as
    for a missing `gh`.
16. **Mixed Workspaces.** Each fetch unit resolves its own Git Platform, so one
    Workspace can have GitHub and GitLab members.
17. **Head commit guard.** A merge from codans merges only the commit that the
    user saw in the badge and the popover:
    - The Pull Request snapshot carries the head commit SHA of the source
      branch (GitHub `headRefOid`, GitLab `diffHeadSha`).
    - The merge write action requires this SHA. GitHub gets it as
      `gh pr merge --match-head-commit`; GitLab gets it as the `sha` of the
      merge API.
    - When the Git Platform refuses the merge because the head moved, codans
      shows its own error ("The branch has new commits. Review them, then
      merge again.") and refreshes the fetch unit at once. The error belongs
      to that Pull Request: it goes when the Worktree changes branch or shows
      a different Pull Request. Otherwise it stays until the user selects
      "Review", also when a failed read shows a CLI error in between. "Review" shows the new head only after a successful read of
      it; before that read, or after a failed read, the button reads it
      again. There is no "merge anyway" action.
    - A snapshot without a SHA (an older cache entry) does not merge. The
      Merge button is disabled, and opening the popover refreshes the fetch
      unit. The user merges after the refresh.

## Reasons

- Users of both Git Platforms run agents in Worktrees and need the same review
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
- One interface keeps Git Platform differences in one place. A third Git Platform
  then needs a new implementation, not changes in the reducer or the views.
- An explicit Pull Request reference does not depend on the working directory,
  so members of one Workspace on different Git Platforms cannot mix up their
  repositories.
- The GitLab project owns its merge method. A client that overrides it breaks
  the rules of the project.
- Without the CI mapping, an optional failed job turns the badge red, and a
  manual job keeps it in progress for all time.
- Agents often push new commits after the user looked at a Pull Request. A
  merge without the head SHA merges commits that nobody reviewed. The Git
  Platform compares the SHA when it merges, so no check in codans can race
  with a push. Some GitLab namespaces also refuse a merge without the SHA.

## Trade-offs

- GitLab users must install `glab` and run `glab auth login`. `glab` is less
  common than `gh`.
- GitLab code paths use the type names `PullRequest…` for merge requests.
- GitLab cannot use the `rebase` strategy as GitHub does.
- Manual jobs that did not run do not show as pending, so the badge does not
  show an open manual deployment.
- Instances that do not report requested changes show fewer review states.
- One default merge strategy applies to both Git Platforms.
- A push between the read and the merge makes the merge fail. The user must
  look at the new commits and merge again.
- Settings has a "Hosts" pane (machines, ADR 0003) and a "Git Platforms" pane.
  The names are close, so the pane text must keep the two concepts apart.
- Host detection needs an auth-status probe of `gh` and a read of the `glab`
  config file. A host whose name contains `gitlab` or `github` but runs another
  Git Platform needs an alias.

## Reconsider when

- A third Git Platform (for example, Gitea or Bitbucket) is requested.
- `glab` cannot provide a needed read or write action.
- Users need GitLab support without installing `glab`.
