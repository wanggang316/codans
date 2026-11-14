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
        shots: ["notifications-1", "notifications-2"],
        title: "Notifications",
        body: "A bell marks the worktree where an agent asked or finished. A macOS banner takes you to the pane.",
        alt: "Two Codans notifications in the macOS Notification Center: Claude waits for input, and a task is complete. Then the sidebar with the Unread filter on: six worktrees with a bell.",
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
    title: "Work in many worktrees at the same time.",
    lede: "Give each task its own worktree and let them all move at once. The sidebar shows the state of every one.",
    points: [
      {
        title: "One task, one worktree",
        body: "Each worktree has its own directory, branch, tabs, and panes. Agents never edit the same checkout.",
      },
      {
        title: "State in the sidebar",
        body: "Diff size, pull request, running commands, and unread bells for every worktree. You see what moved without opening it.",
      },
      {
        title: "Switch without losing your place",
        body: "Tabs and split layouts stay as you left them, across restarts.",
      },
      {
        title: "Built for many terminals",
        body: "Deeply optimized for many terminals that work in parallel: memory stays low and the app stays fast. Terminals that you have not opened stay asleep.",
      },
    ],
    sidebarAlt:
      "The sidebar with five projects and twelve worktrees; most worktrees show a diff size and a pull request number.",
  },
  pr: {
    title: "The pull request, from open to merged.",
    lede: "Codans reads pull requests through the <code>gh</code> and <code>glab</code> CLIs that you are already logged in to. It sends no HTTP request of its own and stores no token.",
    // The capabilities that Settings > Git Platforms lists, in the same order.
    platforms: [
      {
        id: "github",
        name: "GitHub",
        via: "Through <code>gh</code>, on github.com.",
        items: [
          { text: "Pull Request badges" },
          { text: "Check status" },
          { text: "Create merge commit" },
          { text: "Squash and merge" },
          { text: "Rebase and merge" },
          { text: "Mark ready for review" },
          { text: "Rerun failed checks" },
          { text: "Review status" },
        ],
      },
      {
        id: "gitlab",
        name: "GitLab",
        via: "Through <code>glab</code>, on gitlab.com or self-managed.",
        items: [
          { text: "Merge Request badges" },
          { text: "Pipeline status" },
          { text: "Merge" },
          { text: "Squash and merge" },
          { text: "Rebase and merge", unsupported: "The project's merge method applies" },
          { text: "Mark ready" },
          { text: "Retry failed pipeline jobs" },
          { text: "Review status" },
        ],
      },
    ],
  },
  more: {
    projects: {
      title: "Projects",
      lede: "Work across several repositories in one workspace, and on projects that live on another machine. Filters keep the sidebar short.",
      // One item for each sidebar filter, in the order of the filter bar in the app.
      items: [
        {
          id: "remote",
          tab: "Remote",
          title: "Remote projects",
          body: "Work on a project on another machine as if it were local. Its terminals run over a persistent SSH session, so they survive a dropped connection.",
          alt: "The Codans window with the Remote filter on: a project on a host named Mac mini.",
        },
        {
          id: "workspace",
          tab: "Workspace",
          title: "Workspaces",
          body: "Put several projects in one space and work on them like a monorepo: one branch name, one checkout in each project, one place for your agents.",
          alt: "The Codans window with the Workspace filter on: a workspace with a default group and a release group.",
        },
        {
          id: "pr",
          tab: "PR",
          title: "Pull requests",
          body: "Only the worktrees that have a pull request, each with its number and diff size.",
          alt: "The Codans window with the PR filter on: six worktrees with a pull request.",
        },
        {
          id: "unread",
          tab: "Unread",
          title: "Unread notifications",
          body: "Only the worktrees where an agent asked or finished and you have not looked yet.",
          alt: "The Codans window with the Unread filter on: six worktrees with a bell.",
        },
      ],
    },
    themes: {
      title: "Themes",
      body: "Every Ghostty theme is built in, 463 of them. Choose one for light and one for dark; the window follows the system and takes its colors from the terminal.",
      altSuffix: "theme in the Codans window",
    },
    speed: {
      title: "Quick actions",
      lede: "The actions you use all day are one key or one click away.",
      items: [
        {
          shot: "palette",
          title: "Command palette",
          body: "<kbd>⌘P</kbd> finds every action.",
          alt: "The command palette with the query agent and a list of Launch Agent actions.",
        },
        {
          shot: "run-menu",
          title: "Run commands",
          body: "Bind build, test, and dev-server commands to the Run button. Codans finds the scripts in your project files.",
          alt: "The Run menu with four project commands and the scripts found in package.json.",
        },
        {
          shot: "shortcuts",
          title: "Shortcuts",
          body: "Every action has a shortcut that you can change.",
          alt: "The Shortcuts pane of Settings with a table of actions and key combinations.",
        },
        {
          shot: "open-in",
          title: "Open in your editor",
          body: "<kbd>⌘O</kbd> opens the worktree in your editor.",
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
