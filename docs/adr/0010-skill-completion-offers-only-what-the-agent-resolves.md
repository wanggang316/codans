# 0010. Skill completion offers only what the agent resolves

Status: Accepted.

## Context

The New Agent dialog suggests Agent Skills while the user writes the first
prompt. The suggestion list could come from a simple scan of well-known
folders (`~/.claude/skills`, `~/.agents/skills`, ...). But the agent that
codans launches does not always see those folders:

- A profile with `usesDedicatedHome` runs the agent with
  `HOME=<state>/agent-homes/<profile id>`. Its user-level skills are under
  that directory, which is usually empty.
- A profile can set an environment variable that moves the agent's config
  root (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`).
- Each agent kind reads a different set of directories, and some do not
  walk up from the working directory.
- Plugin skills count only when their plugin is enabled.
- In a remote project the agent runs on another host.
- Each agent calls a skill with a different syntax, and for most agents it
  is not documented whether a skill call in the first CLI argument runs.

## Decision

The completion list shows only skills that the launched agent can resolve
and call:

1. User-level directories resolve against the profile's effective `HOME`
   and the agent's config-root variable from the profile's `envVars`.
2. Each `AgentKind` has one Skill Location in `CodansCore`. Only its
   directories are scanned, with its search depth.
3. Plugin skills appear only when their plugin is enabled.
4. An agent kind gets completion only after a probe skill test on a real
   CLI shows that its Invocation Style works in the first prompt. Until then
   its Invocation Style is `none` and the dialog offers no completion.
5. In a remote project the same rules apply on the remote host: codans
   reads the host's files over the project's SSH connection, resolved
   against the host's `HOME`. A read that fails gives no completion, and
   the Skills button shows why.

## Reasons

- A suggestion the agent cannot resolve does nothing or reaches the agent as
  plain text. The user cannot see this failure.
- One rule explains several boundaries (dedicated home, unverified agents,
  remote projects), so a later change can check itself against it.

## Trade-offs

- Some agents get no completion in the first release, although they may
  support it.
- The Skill Location table must follow agent releases. A wrong entry hides
  skills or shows wrong ones.

## Reconsider when

- An agent exposes a command that lists its resolved skills. Then codans can
  ask the agent and drop its own table for that agent.
