# 0005. Git Platform aliases replace the Project Git Platform choice

Status: Accepted

Supersedes in part: [ADR 0004](0004-gitlab-support-through-glab.md), item 2
(the Project settings step of the resolution order) and item 10 (the Project
"Git Platform" choice).

## Context

ADR 0004 lets the user set the Git Platform of a Project (Auto, GitHub, GitLab)
for a remote host that neither `gh` nor `glab` knows. The choice selects only
the Git Platform kind. The CLI must still reach the API host, and it can only
authenticate a host that it is logged in to. Thus:

- If a CLI knows the remote host, Auto already finds the Git Platform, and the
  choice adds nothing.
- If no CLI knows the remote host, the choice gives a kind but no API host
  that the CLI can use, so the badge still does not show.

The implementation reads the `HostName` of an SSH remote with `ssh -G` and
matches it to a logged-in host, but only when the Project choice is set. This
covers an SSH alias (`git@github-work:…`) and an SSH port that differs from the
API port. It does not cover an SSH host whose name differs from the API host
(`ssh.gitlab.example.com` against `gitlab.example.com`). Also, the user must
set the same choice on each Project of that host.

## Decision

1. **Git Platform aliases in Settings.** The "Git Platforms" settings pane has a
   list of Git Platform aliases. Each alias maps a remote host, as it appears in
   the `origin` URL, to a Git Platform kind and an API host. Example:
   `ssh.gitlab.example.com` → GitLab, `gitlab.example.com`. The remote host
   is unique in the list. One alias applies to every Project and Workspace
   member whose `origin` has that host.
2. **No Project Git Platform choice.** Project settings do not have a Git Platform
   choice. The Project "Git Platform" section keeps the Project overrides of the
   merge strategy and the post-merge action.
3. **Resolution order.** For the `origin` host of a fetch unit:
   1. An alias for the host: its kind and its API host.
   2. `github.com` or a host that `gh` is logged in to: GitHub.
   3. `gitlab.com` or a host that `glab` is logged in to: GitLab.
   4. For an SSH remote only: the `HostName` from `ssh -G`, matched without the
      port to the one logged-in or public host of steps 2 and 3. This step
      runs in every case; it does not need a user setting.
   5. Otherwise: no Git Platform. codans shows no badge and no error.

   [ADR 0004](0004-gitlab-support-through-glab.md) item 2 (amended 2026-11)
   adds a host-name step before step 5 and reads the `glab` hosts from its
   config file.
4. **Alias status.** The pane shows, for each alias, whether the CLI of its
   kind is logged in to its API host, with the same actionable message as for
   a missing login. An alias whose API host is not logged in still resolves,
   so the badge position shows that message.

## Reasons

- A remote host maps to one API host, not one Project. One setting per host
  is less work and cannot disagree between Projects of the same host.
- An explicit API host is the only way to cover an SSH host name that differs
  from the API host. A kind without a host cannot reach the API.
- `ssh -G` only prints configuration and makes no connection, so it is safe
  to run for every SSH remote. It makes common SSH aliases work with no
  setting.
- An alias is checked first, so the user can correct a wrong automatic result.

## Trade-offs

- The Project choice shipped on `main` (not in a release) is removed. A
  settings file that has `projects[pid].git.gitPlatform` loads, and the key is
  ignored and not written again.
- `ssh -G` runs once per SSH remote host and is cached until Re-check, so a
  change to `~/.ssh/config` shows after Re-check.
- The user must know the API host of an instance whose SSH host has another
  name.

## Reconsider when

- A remote host must map to different API hosts for different Projects.
- A Git Platform CLI can resolve an SSH host to its API host itself.
