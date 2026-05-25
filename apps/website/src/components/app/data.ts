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

// ─── per-worktree detail content (drives titlebar / status slot / tab bar / panes when selected) ─

export interface TabConfig {
  id: string;
  title: string;
  busy?: boolean;
  dot?: boolean;
  activeByDefault?: boolean;
}

export interface PaneConfig {
  agent: AgentKind | "shell";
  prompt: string;
  lines: string[];
  waitingPrompt?: boolean;
  greenAccent?: boolean; // last char of last line uses the accent colour
}

export type StatusForm =
  | { kind: "pr"; passing: number; failing: number; pending: number; summary: string }
  | { kind: "inProgress"; message: string }
  | { kind: "success"; message: string }
  | { kind: "warning"; message: string }
  | { kind: "motivational" };

export interface DetailConfig {
  branchLabel: string;
  status: StatusForm;
  tabs: TabConfig[];
  panes: PaneConfig[];
}

const FALLBACK_PANE: PaneConfig = {
  agent: "shell",
  prompt: "❯",
  lines: ["$ # nothing running yet", "  Hit ⌘T to open a new tab."],
};

export const DETAIL: Record<string, DetailConfig> = {
  main: {
    branchLabel: "main",
    status: { kind: "motivational" },
    tabs: [{ id: "t1", title: "shell", activeByDefault: true }],
    panes: [
      {
        agent: "shell",
        prompt: "❯",
        lines: [
          "$ git log --oneline -5",
          "4ad640d5 chore(release): bump to 0.3.0",
          "106a00cf Add Active Agents sidebar view (#70)",
          "9243c20e fix(ghostty): drop isolated deinit",
          "d3d3ed6f chore(release): bump to 0.2.5",
          "66ec9307 test: backfill missing dependency stubs",
        ],
      },
    ],
  },
  "feat-agent-loop": {
    branchLabel: "feat/agent-loop",
    status: {
      kind: "pr",
      passing: 3,
      failing: 0,
      pending: 1,
      summary: "3/4 · Mergeable",
    },
    tabs: [
      { id: "t1", title: "claude" },
      { id: "t2", title: "tests", busy: true, dot: true },
      { id: "t3", title: "vite", activeByDefault: true },
      { id: "t4", title: "git" },
    ],
    panes: [
      {
        agent: "claude-code",
        prompt: "❯",
        lines: [
          "$ claude",
          "✦ Reading apps/mac/touch-code/App/Features/StatusBar/StatusBarFeature.swift",
          "✦ Drafting fix for slot priority resolution",
          "↳ Apply patch? [y/N]",
        ],
        waitingPrompt: true,
      },
      {
        agent: "shell",
        prompt: "❯",
        lines: [
          "$ pnpm dev",
          "  ➜  Local:   http://127.0.0.1:5173/",
          "HMR update /src/sections/Hero.tsx",
          "HMR update /src/components/app/AppShell.tsx",
        ],
      },
    ],
  },
  "fix-race": {
    branchLabel: "fix/race-cond",
    status: {
      kind: "pr",
      passing: 1,
      failing: 2,
      pending: 0,
      summary: "1/3 · checks failing",
    },
    tabs: [
      { id: "t1", title: "claude", busy: true, activeByDefault: true },
      { id: "t2", title: "repro" },
    ],
    panes: [
      {
        agent: "claude-code",
        prompt: "❯",
        lines: [
          "$ claude",
          "✦ Reproducing concurrent dispatch race",
          "✦ Adding actor isolation to runningPanes",
          "✦ Re-running affected suite",
        ],
      },
      {
        agent: "shell",
        prompt: "❯",
        lines: [
          "$ pytest tests/test_race.py -q",
          "FAILED tests/test_race.py::test_concurrent_pane_focus",
          "1 failed, 46 passed in 2.81s",
        ],
      },
    ],
  },
  "test-parallel": {
    branchLabel: "test/parallel",
    status: {
      kind: "pr",
      passing: 2,
      failing: 0,
      pending: 2,
      summary: "2/4 · checks pending",
    },
    tabs: [{ id: "t1", title: "tests", busy: true, activeByDefault: true }],
    panes: [
      {
        agent: "pi",
        prompt: "❯",
        lines: [
          "$ pi run --parallel 8",
          "  spawned 8 workers",
          "  worker-3 · 0014ms · pass",
          "  worker-1 · 0015ms · pass",
          "  worker-5 · 0017ms · pass",
          "  worker-2 · running…",
        ],
      },
    ],
  },
  "ui-landing": {
    branchLabel: "ui/landing",
    status: {
      kind: "pr",
      passing: 4,
      failing: 0,
      pending: 0,
      summary: "Draft · 4/4 ready",
    },
    tabs: [
      { id: "t1", title: "claude" },
      { id: "t2", title: "vite", activeByDefault: true },
    ],
    panes: [
      {
        agent: "opencode",
        prompt: "❯",
        lines: [
          "$ opencode",
          "› proposing 3 edits to src/sections/Hero.tsx",
          "› reading tailwind.config.ts",
          "› idle — waiting for next prompt",
        ],
      },
      {
        agent: "shell",
        prompt: "❯",
        lines: [
          "$ pnpm dev",
          "  ➜  Local:   http://127.0.0.1:5173/",
          "  ✓ ready in 412 ms",
          "HMR update /src/sections/Hero.tsx",
        ],
      },
    ],
  },
  "chore-deps": {
    branchLabel: "chore/deps",
    status: { kind: "success", message: "PR #140 merged 2h ago" },
    tabs: [{ id: "t1", title: "shell", activeByDefault: true }],
    panes: [
      {
        agent: "shell",
        prompt: "❯",
        lines: [
          "$ pnpm up --latest",
          "Progress: resolved 1842, reused 1842",
          "Done in 14.2s",
        ],
      },
    ],
  },
  "perf-io": {
    branchLabel: "perf/io",
    status: { kind: "motivational" },
    tabs: [{ id: "t1", title: "shell", activeByDefault: true }],
    panes: [FALLBACK_PANE],
  },
  "docs-spec": {
    branchLabel: "docs/spec",
    status: { kind: "motivational" },
    tabs: [{ id: "t1", title: "shell", activeByDefault: true }],
    panes: [
      {
        agent: "shell",
        prompt: "❯",
        lines: [
          "$ open docs/product-specs/active-agents-view.md",
          "  Opened in Markdown viewer",
        ],
      },
    ],
  },
};

export interface AgentEntry {
  id: string;
  kind: AgentKind;
  state: AgentState;
  project: string;
  worktree: string;
  /** Sidebar selection target when the row is tapped. Matches a key in `DETAIL`. */
  worktreeId: string;
}

export const AGENTS: AgentEntry[] = [
  {
    id: "p-1",
    kind: "claude-code",
    state: "waitingForInput",
    project: "touch-code",
    worktree: "fix/race-cond",
    worktreeId: "fix-race",
  },
  {
    id: "p-2",
    kind: "codex",
    state: "loading",
    project: "touch-code",
    worktree: "feat/agent-loop",
    worktreeId: "feat-agent-loop",
  },
  {
    id: "p-3",
    kind: "pi",
    state: "finished",
    project: "touch-code",
    worktree: "test/parallel",
    worktreeId: "test-parallel",
  },
  {
    id: "p-4",
    kind: "opencode",
    state: "idle",
    project: "touch-code",
    worktree: "ui/landing",
    worktreeId: "ui-landing",
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

// ─── editor / run-script menu entries ────────────────────────────────────

export interface EditorChoice {
  id: string;
  name: string;
  chord?: string;
  installed: boolean;
  reason?: string;
}

export const EDITOR_CHOICES: EditorChoice[] = [
  { id: "vscode", name: "VS Code", chord: "⌘E", installed: true },
  { id: "cursor", name: "Cursor", installed: false, reason: "not found in /Applications" },
  { id: "zed", name: "Zed", installed: true },
  { id: "xcode", name: "Xcode", installed: true },
  { id: "sublime", name: "Sublime Text", installed: true },
];

export interface RunScript {
  id: string;
  name: string;
  command: string;
  chord?: string;
}

export const RUN_SCRIPTS: RunScript[] = [
  { id: "setup", name: "setup", command: "./scripts/setup.sh", chord: "⌘R" },
  { id: "test", name: "test", command: "pnpm test" },
  { id: "lint", name: "lint", command: "pnpm lint" },
  { id: "build", name: "build", command: "pnpm build" },
];
