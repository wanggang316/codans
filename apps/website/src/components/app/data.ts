/**
 * Sample data for the marketing hero. Picked to cover every Worktree / PR /
 * agent / notification state the real app surfaces, so the screenshot
 * doubles as a feature inventory.
 */

export type PrState = "open" | "draft" | "merged" | "closed";
export type ChecksState = "passing" | "failing" | "pending" | "none";
export type AgentKind = "claude-code" | "codex" | "pi" | "opencode";
export type AgentState = "waitingForInput" | "loading" | "finished" | "idle";

export interface WorktreeRow {
  id: string;
  name: string;
  branch?: string;
  pinned?: boolean;
  isDefault?: boolean;
  synthetic?: boolean;
  unreadBell?: boolean;
  busy?: boolean;
  pr?: { number: number; state: PrState; checks?: ChecksState };
  diff?: { add: number; del: number };
  active?: boolean;
  chord?: string;
}

export interface ProjectGroup {
  id: string;
  name: string;
  expanded: boolean;
  hasUnread?: boolean;
  worktrees: WorktreeRow[];
}

export const PROJECTS: ProjectGroup[] = [
  {
    id: "touch-code",
    name: "touch-code",
    expanded: true,
    worktrees: [
      {
        id: "main",
        name: "main",
        isDefault: true,
        pinned: true,
        diff: { add: 2, del: 5 },
        chord: "⌃1",
      },
      {
        id: "feat-agent-loop",
        name: "feat/agent-loop",
        branch: "feat/agent-loop",
        active: true,
        pr: { number: 142, state: "open", checks: "passing" },
        diff: { add: 184, del: 62 },
        chord: "⌃2",
      },
      {
        id: "fix-race",
        name: "fix/race-cond",
        branch: "fix/race-cond",
        busy: true,
        pr: { number: 143, state: "open", checks: "failing" },
        chord: "⌃3",
      },
      {
        id: "test-parallel",
        name: "test/parallel",
        branch: "test/parallel",
        diff: { add: 24, del: 8 },
        pr: { number: 141, state: "open", checks: "pending" },
        chord: "⌃4",
      },
      {
        id: "ui-landing",
        name: "ui/landing",
        branch: "ui/landing",
        pr: { number: 145, state: "draft", checks: "none" },
        chord: "⌃5",
      },
      {
        id: "chore-deps",
        name: "chore/deps",
        branch: "chore/deps",
        pr: { number: 140, state: "merged", checks: "passing" },
        chord: "⌃6",
      },
      {
        id: "perf-io",
        name: "perf/io",
        branch: "perf/io",
        pr: { number: 138, state: "closed" },
        chord: "⌃7",
      },
      {
        id: "docs-spec",
        name: "docs/spec",
        branch: "docs/spec",
        unreadBell: true,
        chord: "⌃8",
      },
    ],
  },
  {
    id: "supacode",
    name: "supacode",
    expanded: false,
    hasUnread: true,
    worktrees: [],
  },
  {
    id: "ghostty",
    name: "ghostty",
    expanded: false,
    worktrees: [],
  },
  {
    id: "scratch",
    name: "scratch",
    expanded: false,
    worktrees: [],
  },
];

export interface AgentEntry {
  id: string;
  kind: AgentKind;
  state: AgentState;
  project: string;
  worktree: string;
}

export const AGENTS: AgentEntry[] = [
  {
    id: "p-1",
    kind: "claude-code",
    state: "waitingForInput",
    project: "touch-code",
    worktree: "fix/race-cond",
  },
  {
    id: "p-2",
    kind: "codex",
    state: "loading",
    project: "touch-code",
    worktree: "feat/agent-loop",
  },
  {
    id: "p-3",
    kind: "pi",
    state: "finished",
    project: "touch-code",
    worktree: "test/parallel",
  },
  {
    id: "p-4",
    kind: "opencode",
    state: "idle",
    project: "touch-code",
    worktree: "ui/landing",
  },
];

export interface NotificationItem {
  id: string;
  project: string;
  worktree: string;
  body: string;
  age: string;
  unread: boolean;
}

export const NOTIFICATIONS: NotificationItem[] = [
  {
    id: "n-1",
    project: "touch-code",
    worktree: "fix/race-cond",
    body: "Claude is waiting for your input",
    age: "12s",
    unread: true,
  },
  {
    id: "n-2",
    project: "touch-code",
    worktree: "feat/agent-loop",
    body: "Codex finished — 124 tests passed",
    age: "1m",
    unread: true,
  },
  {
    id: "n-3",
    project: "touch-code",
    worktree: "test/parallel",
    body: "pi run completed",
    age: "3m",
    unread: true,
  },
  {
    id: "n-4",
    project: "touch-code",
    worktree: "ui/landing",
    body: "Vite restarted on HMR error",
    age: "8m",
    unread: false,
  },
  {
    id: "n-5",
    project: "supacode",
    worktree: "main",
    body: "PR #88 checks failed",
    age: "21m",
    unread: false,
  },
];

export interface CommandItem {
  id: string;
  title: string;
  subtitle?: string;
  icon: "plus" | "branch" | "book" | "openExt" | "gear" | "search" | "folder" | "bell";
  chord?: string;
}

export const COMMANDS: CommandItem[] = [
  { id: "c-1", title: "New Worktree…", subtitle: "Branch off the current Worktree", icon: "plus", chord: "⌘N" },
  { id: "c-2", title: "Open in VS Code", subtitle: "Active worktree", icon: "openExt", chord: "⌘E" },
  { id: "c-3", title: "Open in Cursor", subtitle: "Active worktree", icon: "openExt" },
  { id: "c-4", title: "Toggle Git Viewer", subtitle: "Right-side overlay", icon: "book", chord: "⌘⌥G" },
  { id: "c-5", title: "Reveal in Finder", icon: "folder", chord: "⌘⇧R" },
  { id: "c-6", title: "Show Unread Notifications", icon: "bell", chord: "⌘U" },
  { id: "c-7", title: "Switch Space…", subtitle: "Work · Side · Experiments", icon: "branch", chord: "⌘⇧S" },
  { id: "c-8", title: "Settings…", icon: "gear", chord: "⌘," },
];
