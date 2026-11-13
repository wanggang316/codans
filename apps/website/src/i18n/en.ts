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
    otherLocale: "中文",
    otherLocaleLabel: "切换到中文",
  },
  hero: {
    title: "Run your coding agents in parallel, in one window.",
    lede: "Codans is a native macOS terminal that keeps every project, worktree, and agent side by side, and shows you which ones are working and which ones need you.",
    download: "Download for macOS",
    copy: "Copy",
    copied: "Copied",
    requirements: "Free and open source. macOS 14 or later, Apple Silicon.",
    shotAlt:
      "The Codans window: a sidebar of projects and worktrees, the Agents View, and a terminal running a coding agent.",
  },
  states: [
    { key: "working", name: "Working", detail: "the agent is busy" },
    { key: "blocked", name: "Blocked", detail: "it is waiting for your answer" },
    { key: "done", name: "Done", detail: "it finished a turn you have not read" },
    { key: "idle", name: "Idle", detail: "it is at its prompt" },
  ],
  agents: {
    lead: "Works with the agents you already run in a terminal:",
    names: ["Claude Code", "Codex", "OpenCode", "Pi"],
    tail: "and anything else with a CLI.",
  },
  features: [
    {
      shot: "new-agent",
      title: "Give every task its own worktree.",
      body: [
        "Press <kbd>⌘⇧N</kbd>, pick a project, name a branch, and write the prompt. Codans creates the git worktree, opens a tab in it, and starts the agent. Your other tasks keep running where they are.",
      ],
      alt: "The New Agent dialog with a project, a new worktree, an agent, and a prompt.",
    },
    {
      shot: "agents-view",
      title: "See which agent needs you.",
      body: [
        "The Agents View lists every agent across every project with its live state. When one stops to ask a question or finishes a turn, you get a notification that takes you straight to its pane.",
      ],
      alt: "The Agents View with agents that are working, blocked, done, and idle.",
    },
    {
      shot: "handoff",
      title: "Hand a task from one agent to another.",
      body: [
        "The agent that did the work writes the briefing. Codans starts the receiver beside it with that briefing as its first prompt, so nothing is lost between models.",
        'Workflows chain these steps into loops such as author and reviewer, written in YAML. <span class="tag">Experimental</span>',
      ],
      alt: "Two panes side by side: one agent hands a task off, and the other starts on the briefing.",
    },
    {
      shot: "review",
      title: "Review the change, then merge it.",
      body: [
        "A read-only diff window shows what the agent changed without resizing your terminal. Pull request status from GitHub and GitLab sits next to each worktree, with merge, checks, and reruns one click away.",
      ],
      alt: "The diff window beside the pull request popover of a worktree.",
    },
  ],
  cli: {
    title: "Script it from any pane.",
    body: [
      "Everything in the window is reachable from the <code>codans</code> command. It is on the PATH of every pane, so you and your agents can create worktrees, start other agents, and read each other's output.",
      "An Agent Skill ships with the app and teaches your agents the commands.",
    ],
  },
  more: {
    title: "Also in the box",
    items: [
      {
        title: "Ghostty inside",
        body: "Terminal rendering is libghostty: fast, GPU-drawn, and compatible with your Ghostty habits.",
      },
      {
        title: "Remote projects over SSH",
        body: "Worktrees and panes on another machine, using the SSH config you already have.",
      },
      {
        title: "Workspaces",
        body: "Group checkouts from several repositories so one agent can work across them.",
      },
      {
        title: "Your editor, one shortcut away",
        body: "Open any worktree in VS Code, Cursor, Zed, or Xcode. Codans is not an IDE and does not try to be.",
      },
      {
        title: "Run commands per project",
        body: "Bind build, test, and dev-server commands to the Run button and to shortcuts.",
      },
      {
        title: "Keyboard first",
        body: "A command palette and customizable shortcuts for every action.",
      },
    ],
  },
  cta: {
    title: "Start with the project you have open.",
    source: "Read the source",
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
