// English strings. This file defines the shape of every locale: `zh.ts` must
// match it, and the type checker reports a missing or extra key.
// Strings that contain markup are rendered with `set:html`.

export const en = {
  meta: {
    title: "Codans: run your coding agents in parallel",
    description:
      "A native macOS terminal that keeps every project, worktree, and coding agent in one window, and shows you which agents need you.",
    changelogTitle: "Changelog: Codans",
  },
  nav: {
    changelog: "Changelog",
    github: "GitHub",
    download: "Download",
    otherLocaleLabel: "切换到中文",
  },
  hero: {
    title: "Run your coding agents in parallel, in one window.",
    lede: "Codans is a native macOS terminal for people who work through coding agents. It gives every task a worktree, every agent a pane, and shows you which ones are working and which ones need you.",
    download: "Download for macOS",
    copy: "Copy",
    copied: "Copied",
    requirements: "Free and open source. macOS 14 or later, Apple Silicon.",
    tabsLabel: "Product tour",
    // One task from start to merge. Each view has its own theme and backdrop.
    views: [
      {
        shot: "hero-palette",
        label: "Command palette",
        alt: "A dark Codans window in front of a mountain on Mars, with the command palette open: New Agent, New Workspace, Open Project and other actions. The Agents View in the sidebar shows agents that work, wait for approval, and are done.",
      },
      {
        shot: "hero-start",
        label: "Start: the New Agent dialog",
        alt: "The New Agent dialog over a light Codans window in front of pink sand dunes: the inboxlm project, a new worktree named feat/label-rules, a prompt, and Claude Code selected.",
      },
      {
        shot: "hero-build",
        label: "Work: an agent beside a dev server",
        alt: "A Codans window in the Gruvbox Dark theme above the blue edge of Earth, with the Moon behind it. Claude Code works in a wide pane beside a narrow pane that runs a dev server.",
      },
      {
        shot: "hero-review",
        label: "Work: an agent beside a live diff",
        alt: "A Codans window in the Rosé Pine Dawn theme on a backdrop of blue waves. Codex works in a narrow pane beside a terminal diff viewer.",
      },
      {
        shot: "hero-team",
        label: "Work: five agents in one worktree",
        alt: "A dark Codans window without the sidebar, above the surface of the Moon. Five panes: Claude Code in the first column, Codex and omp in the second, OpenCode and Pi in the third. Claude Code waits for approval to push.",
      },
      {
        shot: "hero-pr",
        label: "Ship: a GitHub pull request",
        alt: "A light Codans window on a plain green backdrop. The pull request popover under the header shows three passed checks and a Merge button.",
      },
    ],
  },
  agentFirst: {
    name: "Agent-first",
    title: "Built around the agent, not the editor.",
    lede: "Codans knows which panes run agents and what state each one is in. It can start, queue, resume, and hand over their work.",
    cards: [
      {
        shots: ["agents-view-1", "agents-view-2", "agents-view-3"],
        title: "Agents View",
        body: "Every agent in every project, with its live state. Click a row to go to its pane.",
        alt: "The Agents View panel. One agent waits for approval, three work, and then two of them finish.",
      },
      {
        shots: ["new-agent"],
        title: "New Agent",
        body: "Press <kbd>⌘⇧N</kbd>, pick a project, name a branch, write the prompt. The worktree and the agent start together.",
        alt: "The New Agent dialog with a project, a new worktree, a prompt, and an agent.",
      },
      {
        shots: ["queue-1", "queue-2"],
        title: "Command Queue",
        body: "Line up prompts while the agent is busy: after the current task, now, or on a schedule.",
        alt: "The Command Queue dialog with a prompt that repeats every 30 minutes, then the list of three queued commands.",
      },
      {
        shots: ["sessions-1", "sessions-2", "sessions-3"],
        title: "Session History",
        body: "Every Claude Code and Codex session of a worktree. Resume one in a new tab, in place, or in a split.",
        alt: "The Agent Sessions popover with six sessions, the Resume in menu, and then the resumed session in a new split.",
      },
      {
        shots: ["profile"],
        title: "Agent Profiles",
        body: "Launch presets: agent, model, effort, mode, placement, arguments, and environment.",
        alt: "The Agents pane of Settings with a profile that starts Claude Code with the Opus model in plan mode.",
      },
      {
        shots: ["handoff"],
        title: 'Workflows <span class="tag">Beta</span>',
        body: "Hand a task to another agent with a briefing, or chain agents into loops such as author and reviewer.",
        alt: "The Hand Off panel with a list of agent profiles and Codex Reviewer selected.",
      },
      {
        shots: ["notifications"],
        title: "Notifications",
        body: "A bell marks the worktree where an agent asked or finished. A macOS banner takes you to the pane.",
        alt: "The sidebar with the Unread filter on: six worktrees with a bell.",
      },
      {
        shots: ["persistence"],
        title: "Sessions outlive the window",
        body: "Quit Codans and the agents keep working. The next launch brings every terminal back.",
        alt: "The quit dialog: six panes are busy, with the choices Keep session running, Snapshot and exit, and Cancel.",
      },
      {
        shots: ["cli-1", "cli-2"],
        title: "CLI and Agent Skill",
        body: "Everything in the window is a <code>codans</code> command. Agents use it to create worktrees, start other agents, and read their output.",
        alt: "A terminal that runs codans agent status, then a Codex prompt that asks it to use the codans skill to open a worktree and start an agent.",
      },
    ],
  },
  parallel: {
    name: "Parallel",
    title: "Many projects, many worktrees, one window.",
    lede: "Parallel work fails when you lose track of it. Codans keeps the whole tree in the sidebar and each line of work in its own directory.",
    points: [
      {
        title: "Worktrees are first-class",
        body: "A project lists its git worktrees. Each one has its own directory, branch, tabs, and panes, so two agents never edit the same checkout unless you want them to.",
      },
      {
        title: "State at every level",
        body: "The sidebar shows the diff size, the pull request, running commands, and unread bells for each worktree. You see what moved without opening it.",
      },
      {
        title: "Switching is instant",
        body: "Tabs and split layouts stay as you left them, in every worktree, across restarts.",
      },
    ],
    sidebarAlt:
      "The sidebar with five projects and twelve worktrees; most worktrees show a diff size and a pull request number.",
    teamTitle: "Five agents, one worktree",
    teamBody: "A recording of the layout from the tour: each pane is an agent with its own job on the same branch.",
    teamAlt: "A screen recording of five agent panes that produce output at the same time.",
    layoutTitle: "A pane is a real terminal",
    layoutBody:
      "Rendering is libghostty, so anything that runs in Ghostty runs here: an agent, a system monitor, a git graph, or a game of Snake while the tests run.",
    layoutAlt: "Four panes: Claude Code, htop, a Snake game, and a git log graph.",
    statsTitle: "Measured with real agents",
    stats: [
      { value: "14", label: "agents running at the same time, in 20 panes across 5 projects" },
      { value: "0.6%", label: "CPU used by Codans while they wait, and about 5% while they stream output" },
      { value: "200 MB", label: "app memory with one worktree on screen" },
      { value: "1.1 MB", label: "for each session daemon that keeps a pane alive" },
    ],
    statsNote:
      "Codans 0.12.1 on an 8-core Apple Silicon Mac with 16 GB of memory. Terminals that you have not opened stay asleep. After every one of the 20 terminals was opened, the app used about 600 MB. The agents use their own memory.",
  },
  pr: {
    name: "Pull requests",
    title: "The pull request, from open to merged, without the browser.",
    lede: "Codans reads pull requests through the <code>gh</code> and <code>glab</code> CLIs that you are already logged in to. It sends no HTTP request of its own and stores no token.",
    cards: [
      {
        shot: "pr-popover",
        title: "GitHub",
        body: "The badge of a worktree follows the pull request of its branch. The popover shows the checks and lets you merge, close, mark ready, or rerun failed checks.",
        alt: "A GitHub pull request popover with three passed checks and a Merge (squash) button.",
      },
      {
        shot: "mr-popover",
        title: "GitLab",
        body: "Merge requests work the same way, on gitlab.com and on self-managed instances, with the pipeline jobs as checks.",
        alt: "A GitLab merge request popover with three passed pipeline jobs and a Merge (squash) button.",
      },
    ],
    capsTitle: "What you can do from the window",
    caps: [
      "Pull request and merge request badges on every worktree",
      "Check and pipeline status, updated while you work",
      "Merge commit, squash and merge, rebase and merge",
      "Mark a draft as ready for review",
      "Rerun failed checks",
      "Review status and the reason a merge is blocked",
    ],
    diffTitle: "Read the change first",
    diffBody:
      "A read-only diff window shows what the agent changed: uncommitted work, or everything the branch adds to its base. Unified or split, with a file tree, and without resizing your terminal.",
    diffAlt: "The diff window in split layout with a file tree of eleven changed files.",
  },
  more: {
    name: "And the rest",
    title: "The parts you set up once and then rely on.",
    projects: {
      title: "Projects",
      items: [
        {
          shot: "filter-workspace",
          title: "Workspaces",
          body: "Group checkouts from several repositories for one task. One branch name, one checkout in each project.",
          alt: "The sidebar with the Workspace filter: a workspace with a default group and a release group.",
        },
        {
          shot: "filter-remote",
          title: "Remote projects",
          body: "Worktrees and panes on another machine over SSH, with the SSH config you already have.",
          alt: "The sidebar with the Remote filter: a project on a host named Mac mini.",
        },
        {
          shot: "filter-pr",
          title: "Filters",
          body: "Cut the sidebar down to remote projects, workspaces, worktrees with a pull request, or worktrees with unread notifications.",
          alt: "The sidebar with the PR filter: six worktrees with a pull request.",
        },
      ],
    },
    themes: {
      title: "Themes",
      body: "Every Ghostty theme is built in, 463 of them. Choose one for light and one for dark; the window follows the system and takes its colors from the terminal.",
      items: [
        { shot: "theme-tokyonight", name: "TokyoNight Storm" },
        { shot: "theme-rosepine", name: "Rose Pine Dawn" },
        { shot: "theme-gruvbox", name: "Gruvbox Dark" },
        { shot: "theme-latte", name: "Catppuccin Latte" },
        { shot: "theme-mocha", name: "Catppuccin Mocha" },
      ],
      altSuffix: "theme in the Codans window",
    },
    speed: {
      title: "Speed",
      items: [
        {
          shot: "palette",
          title: "Command palette",
          body: "<kbd>⌘P</kbd> finds every action: switch worktree, launch an agent, run a command, split a pane.",
          alt: "The command palette with the query agent and a list of Launch Agent actions.",
        },
        {
          shot: "run-menu",
          title: "Project and global commands",
          body: "Bind build, test, and dev-server commands to the Run button and to shortcuts. Codans reads package.json, Makefile, justfile, Cargo.toml and more, and offers the commands it finds.",
          alt: "The Run menu with four project commands and the scripts found in package.json.",
        },
        {
          shot: "shortcuts",
          title: "Shortcuts for everything",
          body: "Every action has a shortcut that you can change, disable, or search for.",
          alt: "The Shortcuts pane of Settings with a table of actions and key combinations.",
        },
        {
          shot: "open-in",
          title: "Your editor, one key away",
          body: "<kbd>⌘O</kbd> opens the worktree in VS Code, Cursor, Zed, Xcode, or a JetBrains IDE. Codans is not an IDE and does not try to be.",
          alt: "The Open in menu with a list of editors, terminals, and git clients.",
        },
      ],
    },
  },
  cta: {
    title: "Start with the project you have open.",
    source: "View on GitHub",
  },
  footer: {
    releases: "Releases",
    issues: "Issues",
    repo: "Repository",
  },
  changelog: {
    title: "Changelog",
    subtitle: "Every release of Codans, newest first.",
    latest: "Latest",
    kinds: {
      Added: "Added",
      Changed: "Changed",
      Deprecated: "Deprecated",
      Removed: "Removed",
      Fixed: "Fixed",
      Security: "Security",
    },
  },
};

type Widen<T> = T extends string
  ? string
  : T extends readonly (infer U)[]
    ? Widen<U>[]
    : { [K in keyof T]: Widen<T[K]> };

export type Dictionary = Widen<typeof en>;
