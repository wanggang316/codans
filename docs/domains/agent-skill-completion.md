# Agent Skill Completion

An agent can call an Agent Skill by a short token in its prompt (`/review`, `$review`). Users install many skills, spread over user-level folders, project folders, and plugin caches, and each agent kind reads different folders and uses a different token. Skill completion lists, while the user writes a prompt, the skills that the selected agent will really find, and inserts the token that this agent understands. The terms Agent Skill, Skill Location, and Invocation Style are in the [glossary](../glossary.md#agent-skills).

## Scope and ownership

This page owns the Skill Location of each agent kind, the resolution of skill directories, the skill scan, and the completion list in the prompt composers.

Neighbor topics:

- Installing the bundled skills (`codans skill install`): [CLI](cli.md).
- Agent kinds and how codans detects the agent in a Pane: [Agent state](agent-state.md).
- Agent profiles, the dedicated home, and the New Agent launch: [Agent profiles and handoff](agent-profiles-and-handoff.md).
- The Command Queue panel: [Command queue](command-queue.md).
- SSH connections and Hosts: [Remote projects](remote-projects.md).

## The principle

The list offers only what the launched agent can resolve and call ([ADR 0010](../adrs/0010-skill-completion-offers-only-what-the-agent-resolves.md)). A suggestion that the agent cannot resolve reaches it as plain text, and the user does not see the failure. Each rule below follows from this one. When codans cannot be sure what the agent reads, it offers less, not more.

Completion is a selection aid, not an execution guarantee. The app inserts the token at the caret and keeps the rest of the prompt. It does not move the token, expand the skill, or hide a skill because of `disable-model-invocation`. The agent decides how the call resolves and runs.

The app reads only the name and the description of a skill (from the `SKILL.md` frontmatter) to show the list. It never loads or runs a skill.

## Where completion appears

- **New Agent dialog.** The prompt field. The list is for the selected agent profile, in the selected project and target.
- **Command Queue composer.** The draft field. The list is for the agent that runs now in the target Pane.
- **Skills button.** In the footer of both composers. It inserts the call prefix at the caret (at the prompt start for an agent that accepts calls only there), so the same list opens.

Typing the agent's prefix at the start of a token opens the list. The filter matches name and description, and a name prefix match comes first. Return or Tab inserts the highlighted skill, the arrow keys move the highlight, and Escape closes only the list. When the list is closed, Return and Escape keep their normal meaning in the host composer. During input-method composition, all these keys go to the input method. The list is a child window of the composer window, so it does not take focus or change the dialog size. A second child window shows the full description of the highlighted row.

## Skill Location

Each `AgentKind` has exactly one `SkillLocation` in `CodansCore`. It is a closed table, not a user setting. It gives:

- **User directories**, relative to the effective home.
- **A config root** that an environment variable can move, and the user directory under it.
- **Project directories**, each with its search depth: the start directory only, or each parent up to the repository root (the first directory that has a `.git` entry). Without a repository root, only the start directory is read.
- **A project trust check**, for an agent that reads project skills only in a trusted project.
- **A plugin source**: the enabled plugins of the agent add skills named `<plugin>:<skill>`.
- **Precedence**: which source keeps a name that more than one source has.
- **The Invocation Style and position**: the token, and whether a call works anywhere in the prompt or only at its start.

| Agent | User directories | Project directories | Plugins | Token |
|---|---|---|---|---|
| Claude Code | `.claude/skills` (config root `CLAUDE_CONFIG_DIR`) | `.claude/skills`, walk up | Enabled Claude Code plugins | `/name`, `/plugin:skill` |
| Codex | `.agents/skills`, `.codex/skills` (config root `CODEX_HOME`) | `.agents/skills`, walk up | Enabled Codex plugins | `$name`, `$plugin:skill` |
| Pi | `.pi/agent/skills` (config root `PI_CODING_AGENT_DIR`), `.agents/skills` | `.pi/skills` start only, `.agents/skills` walk up; only in a trusted project | none | `/skill:name` |

For these three agents, a call works at any position in the prompt. Claude Code keeps a user skill over a project skill with the same name; Codex and Pi keep the project skill. In one source, a nearer directory wins.

Every other agent kind has the Invocation Style `none` and gets no completion. An agent gets a style only after a probe skill on its real CLI shows that the token runs in the first prompt. A documented syntax is not enough: for example, an agent that cannot take a first prompt at launch gives the token no chance to run. Add a new agent to the table only with such a probe.

## Directory resolution

`SkillLocationResolver` turns a launch and a start directory into the list of directories to scan.

- **Effective home.** A profile with a dedicated home resolves against `<state>/agent-homes/<profile id>`. Otherwise a `HOME` in the profile environment applies, else the user home. A dedicated home is usually empty, so the list then has no user skills. This is correct: the agent sees none either.
- **Config root.** When the profile environment sets the agent's config-root variable, its value replaces the default root, and the user directory under the root moves with it. A relative value cannot be placed, so that directory and the plugins are left out.
- **Launch arguments.** Some agent flags change the skills (Claude Code `--settings`, Codex `--profile` and `--enable plugins`, Pi `--no-skills` and `--approve`). The extra arguments of a profile are a shell fragment. codans reads them only when they are plain words (`PlainShellWords`). Otherwise the result is unknown, and the skills that depend on the flags are left out: plugin skills, and for Pi all skills.
- **Plugins.** Only enabled plugins count. Claude Code: the plugin registry under the config root, filtered by `enabledPlugins` merged over the user, project, local, `--settings`, and managed settings. Codex: the plugin cache, filtered by `config.toml` and the `--profile` layer. A registry or config that is missing, cannot be parsed, or has a form codans does not read gives no plugin skills. A project `.codex/config.toml` that mentions plugins also gives none, because codans cannot see whether Codex trusts the project.
- **Pi project trust.** Pi loads project skills only in a project it trusts, and an untrusted project skill with the same name can block a user skill. `PiProjectTrust` lists project directories only when Pi will trust the project without asking: `--approve`, a saved `true` decision in Pi's `trust.json`, or `defaultProjectTrust` set to `always`. Any extension can decide trust, so its presence gives no project skills.

### Start directory

The project directories are searched from the directory where the agent will start:

- **Existing worktree.** The worktree directory of the target branch.
- **Folder or Workspace project.** Its one working directory.
- **New worktree.** This includes a branch that no worktree holds. The directory does not exist yet, and the main checkout has other files than the new worktree will have. `NewWorktreeFiles` builds a temporary view that holds only the project paths that completion reads: tracked files from the source ref (through a private git index, as `git worktree add` checks them out), plus the main-checkout files that the Copy ignored files and Copy untracked files options will copy. The scan runs on the view, then the view is deleted. A change of base ref or copy options scans again. Without a resolved ref, or when git fails, only user skills are listed. Pi does not list project skills for a new worktree unless `--approve` is set, because no trust decision can exist for a path that does not exist.

## Remote projects

In a Remote Project the agent runs on the Host, so its home, plugins, and project files are on the Host.

- **New Agent dialog.** The same resolver and scanner run against the Host. All file reads go through `SkillFileSystem`. `RemoteSkillReader` runs the resolution on a `SkillFileSnapshot`, collects the reads it could not answer, sends them to the Host in one `sh` script over the project's shared SSH connection, and repeats until no new read is needed. Paths go as script arguments, never as script text. The user directories resolve against the Host `$HOME`. A dedicated home is a path under the state root of this Mac, which the Host usually does not have, so a remote profile with one usually gets no user skills. A new worktree uses a view on the Host (`RemoteNewWorktreeFiles`) with tracked files only, because a remote worktree copies no ignored or untracked files.
- **Command Queue composer.** No completion: "Skill suggestions are not available for remote projects". The agent process is on the Host, and codans cannot read its arguments and environment.

The remote read runs in the background, and the dialog stays usable. When it fails (no connection, timeout, a reply that cannot be parsed, too many rounds), the list is empty and the Skills button shows the reason. When the Host record of the project is missing, the project still counts as remote, and the app does not read local paths with the same names.

## The running agent (Command Queue)

The Command Queue completes for the agent that runs in the target Pane, not for a profile. codans finds the agent process in the Pane's foreground process group and reads its argv and environment from the kernel. It keeps only `HOME` and the agent's config-root variable. So the list follows how the agent really started, also when the shell or the project environment set these values. The process's current directory is the start directory; when it cannot be read, the Pane working directory applies. The argv words are already expanded by the shell, so the plain-words rule does not apply. A word that still starts with `~` was quoted, and the arguments are then unknown.

While the panel is open, it follows the Pane. When the agent process, its launch, or its directory changes, the old list goes at once and a new scan starts. When the agent exits, the list closes.

## When completion is not available

The list does not open, and the Skills button is disabled with a tooltip:

| Case | Reason shown |
|---|---|
| New Agent: no project, or no agent | "Add a project to see its skills" / "Choose an agent to see its skills" |
| Agent with Invocation Style `none` | "Skill suggestions are not available for <agent>" |
| New Agent: remote read failed | The failure, for example "Could not connect to <host>: …" |
| New Agent: Host record missing | "The host of this remote project is not available" |
| Command Queue: no agent detected in the Pane | "Skill suggestions need an agent running in this pane" |
| Command Queue: process, argv, environment, or an absolute `HOME` not readable | "Skill suggestions are not available: codans cannot read how this agent was started" |
| Command Queue: Remote Project | "Skill suggestions are not available for remote projects" |

## Scan and freshness

`SkillScanner` reads `*/SKILL.md` in each directory off the main actor and removes duplicate names by precedence. A skill with broken frontmatter is still listed by its folder name, without a description. There is no file watch and no cache across sessions. The New Agent dialog scans again when the agent, the project, the target, or the new-worktree source changes. Each result is tied to the scope that requested it (profile, start directory, new-worktree source). A result for an old scope is dropped, and a scope change clears the list at once, so the list never shows the skills of another agent or directory.

## Shape of the implementation

```
CodansCore/Agents                         app
-----------------                         ---
SkillLocation (per AgentKind)             NewAgentFeature ----+
SkillLaunch (profile | running process)   CommandQueueFeature-+-> AgentSkillClient
SkillLocationResolver + plugin registries                         |  local: NewWorktreeFiles
  + PiProjectTrust                                                |  remote: RemoteSkillReader
SkillScanner      <-- SkillFileSystem (local | snapshot) <--------+
                                                                  v
                            Composer: ComposerSkillCompletion + panels (shared UI)
```

The rules live in `CodansCore` and are pure over a `SkillFileSystem`, so one implementation serves local disks, Hosts, and tests. The two features only choose the launch and the start directory. The composer component in `App/Features/Composer/` does not depend on either feature.
