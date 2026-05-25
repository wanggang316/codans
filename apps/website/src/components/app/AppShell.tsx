import { useEffect, useState } from "react";
import { motion, AnimatePresence } from "framer-motion";
import {
  AgentClaude,
  AgentCodex,
  AgentOpenCode,
  AgentPi,
  ArrowUpRight,
  Bell,
  BellFill,
  Book,
  CaretDown,
  CheckCircleFill,
  ChevronDown,
  ChevronRight,
  CircleDashed,
  ClockCircleFill,
  Ellipsis,
  Folder,
  Gear,
  GitBranch,
  GitMerge,
  GitPullRequest,
  GitPullRequestClosed,
  GitPullRequestDraft,
  LoadingGrid,
  PauseFill,
  PinFill,
  Plus,
  Search,
  StarFill,
  XCircleFill,
} from "./icons";
import {
  AGENTS,
  AgentEntry,
  AgentKind,
  AgentState,
  COMMANDS,
  CommandItem,
  NOTIFICATIONS,
  NotificationItem,
  PROJECTS,
  PrState,
  WorktreeRow as RowData,
} from "./data";

// ─── palette ─────────────────────────────────────────────────────────────

const PR_TINT: Record<PrState, string> = {
  open: "text-[#3FB950]",
  draft: "text-[#8B949E]",
  merged: "text-[#A371F7]",
  closed: "text-[#F85149]",
};

const PR_BADGE_BG: Record<PrState, string> = {
  open: "bg-[#102818]/80 text-[#7EE0A0] border-[#1F5F33]",
  draft: "bg-[#1A1D22]/80 text-[#B0B7BE] border-[#373E47]",
  merged: "bg-[#2A1F4A]/80 text-[#D2B7FF] border-[#6E40C9]/60",
  closed: "bg-[#2E1418]/80 text-[#FFA8A6] border-[#8E2D2D]",
};

function prIcon(state: PrState) {
  switch (state) {
    case "open":
      return GitPullRequest;
    case "draft":
      return GitPullRequestDraft;
    case "merged":
      return GitMerge;
    case "closed":
      return GitPullRequestClosed;
  }
}

const SIDEBAR_W = 260;

// ─── outer shell ─────────────────────────────────────────────────────────

type Overlay = "bell" | "palette" | null;

export default function AppShell() {
  const [agentsOpen, setAgentsOpen] = useState(true);
  const [overlay, setOverlay] = useState<Overlay>(null);

  // Cadence: agents panel open with no overlay (initial) → bell popover →
  // command palette → command palette closes + agents panel slides back in.
  // Each beat is ~5.2s so a visitor sees every surface within ~16s.
  useEffect(() => {
    const beats: Array<{ agents: boolean; overlay: Overlay }> = [
      { agents: true, overlay: null },
      { agents: true, overlay: "bell" },
      { agents: false, overlay: "palette" },
      { agents: true, overlay: null },
    ];
    let i = 0;
    const id = window.setInterval(() => {
      i = (i + 1) % beats.length;
      setAgentsOpen(beats[i].agents);
      setOverlay(beats[i].overlay);
    }, 5200);
    return () => window.clearInterval(id);
  }, []);

  return (
    <div className="relative">
      <div className="relative overflow-hidden rounded-[12px] border border-line bg-[#0d0d10] shadow-window">
        <TitleBar overlay={overlay} setOverlay={setOverlay} />
        <div
          className="relative grid h-[560px]"
          style={{ gridTemplateColumns: `${SIDEBAR_W}px 1fr` }}
        >
          <Sidebar agentsOpen={agentsOpen} onAgentsToggle={() => setAgentsOpen((o) => !o)} />
          <Detail />

          {/* Full-window overlays */}
          <AnimatePresence>
            {overlay === "palette" && <CommandPaletteOverlay key="palette" />}
          </AnimatePresence>
        </div>
      </div>
    </div>
  );
}

// ─── titlebar — spans whole window ───────────────────────────────────────

function TitleBar({ overlay, setOverlay }: { overlay: Overlay; setOverlay: (o: Overlay) => void }) {
  return (
    <div
      className="relative grid h-11 items-center border-b border-line/70 bg-[#161618]/95 backdrop-blur-xl"
      style={{ gridTemplateColumns: `${SIDEBAR_W}px 1fr` }}
    >
      {/* sidebar half */}
      <div className="flex h-full items-center gap-2 px-3">
        <div className="flex shrink-0 gap-1.5">
          <button
            type="button"
            aria-label="Close"
            className="grid h-3 w-3 place-items-center rounded-full bg-[#ff5f57] transition hover:brightness-110 active:brightness-90"
          />
          <button
            type="button"
            aria-label="Minimize"
            className="h-3 w-3 rounded-full bg-[#febc2e] transition hover:brightness-110"
          />
          <button
            type="button"
            aria-label="Zoom"
            className="h-3 w-3 rounded-full bg-[#28c840] transition hover:brightness-110"
          />
        </div>
        <div className="flex-1" />
        <ToolbarChip ariaLabel="Add Project" help="Add Project">
          <Plus size={12} />
          <span className="ml-1 text-[12px]">Add Project</span>
        </ToolbarChip>
      </div>

      {/* hairline column divider — sits flush in the titlebar so the two
          column toolbars read as adjacent regions. */}
      <span
        aria-hidden
        className="absolute top-2 bottom-2 w-px bg-line"
        style={{ left: SIDEBAR_W - 0.5 }}
      />

      {/* detail half */}
      <div className="relative flex h-full items-center gap-2 px-3">
        <BranchIdentityChip />
        <div className="flex-1" />
        <StatusSlot />
        <BellChip
          active={overlay === "bell"}
          onClick={() => setOverlay(overlay === "bell" ? null : "bell")}
        />
        <div className="flex-1" />
        <RunScriptSplitButton />
        <OpenInSplitButton />
        <ToolbarChip ariaLabel="Settings" help="Settings">
          <Gear size={14} />
        </ToolbarChip>

        {/* notifications popover anchored under the bell */}
        <AnimatePresence>
          {overlay === "bell" && <NotificationsPopover key="bell" />}
        </AnimatePresence>
      </div>
    </div>
  );
}

/**
 * Generic toolbar chip — matches the look macOS 26 ships with via its
 * glass-capsule treatment on `ToolbarItem` content: subtle rounded
 * background, soft border, hover wash, snug height.
 */
function ToolbarChip({
  children,
  ariaLabel,
  onClick,
  active,
  help,
  className = "",
}: {
  children: React.ReactNode;
  ariaLabel?: string;
  onClick?: () => void;
  active?: boolean;
  help?: string;
  className?: string;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      title={help}
      aria-label={ariaLabel}
      className={`inline-flex h-7 cursor-pointer items-center gap-1 rounded-md border px-2 text-ink/90 transition-colors ${
        active
          ? "border-leaf-500/60 bg-leaf-700/15 text-leaf-50"
          : "border-line/70 bg-ink/[0.04] hover:bg-ink/[0.07]"
      } focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-leaf-300/60 ${className}`}
    >
      {children}
    </button>
  );
}

function BranchIdentityChip() {
  // Mirrors WorktreeHeaderInfoLabel: WorktreeRowIcon + name (headline) +
  // branch subtitle (caption monospaced) when branch differs from name.
  const branch = "feat/agent-loop";
  return (
    <button
      type="button"
      className="group flex h-8 cursor-default items-center gap-2 rounded-md px-1.5 transition-colors hover:bg-ink/[0.04]"
    >
      <span className="relative grid h-[18px] w-[18px] place-items-center text-[#3FB950]">
        <GitPullRequest size={16} />
        <span className="absolute -bottom-0.5 -right-0.5 text-[#3FB950]">
          <CheckCircleFill size={9} />
        </span>
      </span>
      <span className="flex flex-col">
        <span className="text-[12.5px] font-semibold leading-none text-ink">{branch}</span>
        <span className="mt-0.5 font-mono text-[10.5px] leading-none text-ink-muted">
          touch-code
        </span>
      </span>
    </button>
  );
}

function BellChip({ active, onClick }: { active?: boolean; onClick?: () => void }) {
  return (
    <ToolbarChip
      onClick={onClick}
      ariaLabel="Notifications"
      help="Show Unread Notifications (⌘U)"
      active={active}
      className="pl-1.5 pr-2"
    >
      <span className="text-[#FFA657]">
        <BellFill size={14} />
      </span>
      <span className="font-mono text-[11px] font-semibold tabular-nums text-ink">3</span>
    </ToolbarChip>
  );
}

function RunScriptSplitButton() {
  return (
    <div className="flex h-7 overflow-hidden rounded-md border border-line/70 bg-ink/[0.04]">
      <button
        type="button"
        title="Run script"
        className="flex items-center gap-1.5 px-2 text-[12px] text-ink hover:bg-ink/[0.06]"
      >
        <svg width="11" height="11" viewBox="0 0 16 16" fill="currentColor" className="text-leaf-300">
          <path d="M4 3l9 5-9 5V3z" />
        </svg>
        <span>Run</span>
      </button>
      <span className="w-px self-stretch bg-line/80" />
      <button
        type="button"
        aria-label="Choose script"
        className="grid w-6 place-items-center text-ink-muted hover:bg-ink/[0.06] hover:text-ink"
      >
        <CaretDown size={10} />
      </button>
    </div>
  );
}

function OpenInSplitButton() {
  return (
    <div className="flex h-7 overflow-hidden rounded-md border border-line/70 bg-ink/[0.04]">
      <button
        type="button"
        title="Open in VS Code (⌘E)"
        className="flex items-center gap-1.5 px-2 text-[12px] text-ink hover:bg-ink/[0.06]"
      >
        <ArrowUpRight size={12} />
        <span>Open in</span>
      </button>
      <span className="w-px self-stretch bg-line/80" />
      <button
        type="button"
        aria-label="Choose editor"
        className="grid w-6 place-items-center text-ink-muted hover:bg-ink/[0.06] hover:text-ink"
      >
        <CaretDown size={10} />
      </button>
    </div>
  );
}

// ─── status slot ─────────────────────────────────────────────────────────

function StatusSlot() {
  const states = ["pr", "inProgress", "success", "motivational"] as const;
  type S = (typeof states)[number];
  const [i, setI] = useState(0);
  useEffect(() => {
    const id = window.setInterval(() => setI((n) => (n + 1) % states.length), 3800);
    return () => window.clearInterval(id);
  }, []);
  const s: S = states[i];

  return (
    <div className="relative h-7 w-[260px] overflow-visible rounded-md border border-line/70 bg-ink/[0.04]">
      <AnimatePresence mode="wait">
        {s === "pr" && (
          <SlotShell key="pr">
            <PRBadgePill number={142} state="open" />
            <ChecksRing passing={3} failing={0} pending={1} />
            <span className="font-mono text-[11.5px] text-ink-muted">3/4 · Mergeable</span>
          </SlotShell>
        )}
        {s === "inProgress" && (
          <SlotShell key="ip">
            <Spinner size={11} />
            <span className="font-mono text-[11.5px] text-ink-muted">
              Running <span className="text-ink">setup.sh</span>
            </span>
          </SlotShell>
        )}
        {s === "success" && (
          <SlotShell key="ok">
            <span className="text-[#3FB950]">
              <CheckCircleFill size={13} />
            </span>
            <span className="font-mono text-[11.5px] text-ink-muted">Opened in Xcode</span>
          </SlotShell>
        )}
        {s === "motivational" && (
          <SlotShell key="mv">
            <span aria-hidden>🌇</span>
            <span className="font-mono text-[11.5px] text-ink-muted">
              17:42 · <span className="text-ink">⌘P</span> Command Palette
            </span>
          </SlotShell>
        )}
      </AnimatePresence>
    </div>
  );
}

function SlotShell({ children }: { children: React.ReactNode }) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 4 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, y: -4 }}
      transition={{ duration: 0.22, ease: "easeInOut" }}
      className="absolute inset-0 flex items-center justify-center gap-2"
    >
      {children}
    </motion.div>
  );
}

function ChecksRing({
  passing,
  failing,
  pending,
}: {
  passing: number;
  failing: number;
  pending: number;
}) {
  const total = passing + failing + pending || 1;
  const slices = [
    { v: passing, color: "#3FB950" },
    { v: failing, color: "#F85149" },
    { v: pending, color: "#D29922" },
  ];
  let acc = 0;
  return (
    <svg width="14" height="14" viewBox="-1 -1 22 22">
      <circle cx="10" cy="10" r="9" fill="none" stroke="#1F1F22" strokeWidth="3" />
      {slices.map((s, i) => {
        if (s.v === 0) return null;
        const start = (acc / total) * Math.PI * 2;
        acc += s.v;
        const end = (acc / total) * Math.PI * 2;
        const r = 9;
        const x1 = 10 + r * Math.sin(start);
        const y1 = 10 - r * Math.cos(start);
        const x2 = 10 + r * Math.sin(end);
        const y2 = 10 - r * Math.cos(end);
        const large = end - start > Math.PI ? 1 : 0;
        return (
          <path
            key={i}
            d={`M ${x1} ${y1} A ${r} ${r} 0 ${large} 1 ${x2} ${y2}`}
            stroke={s.color}
            strokeWidth="3"
            fill="none"
            strokeLinecap="butt"
          />
        );
      })}
    </svg>
  );
}

function PRBadgePill({ number, state }: { number: number; state: PrState }) {
  return (
    <span
      className={`inline-flex items-center gap-1 rounded border px-1.5 py-[1px] font-mono text-[10px] tabular-nums ${PR_BADGE_BG[state]}`}
    >
      #{number}
    </span>
  );
}

function Spinner({ size = 12 }: { size?: number }) {
  return (
    <span
      style={{ width: size, height: size }}
      className="inline-block animate-spin rounded-full border-[1.4px] border-leaf-500/40 border-t-leaf-300"
    />
  );
}

// ─── sidebar ─────────────────────────────────────────────────────────────

function Sidebar({
  agentsOpen,
  onAgentsToggle,
}: {
  agentsOpen: boolean;
  onAgentsToggle: () => void;
}) {
  return (
    <aside className="relative flex flex-col bg-[#101013]">
      {/* list region */}
      <div className="flex-1 overflow-hidden px-1.5 py-1.5">
        {PROJECTS.map((p) =>
          p.expanded ? (
            <div key={p.id} className="mb-1">
              <ProjectHeader name={p.name} expanded hasUnread={p.hasUnread} />
              <ul className="mt-0.5 space-y-px">
                {p.worktrees.map((w) => (
                  <WorktreeRowView key={w.id} row={w} />
                ))}
              </ul>
            </div>
          ) : (
            <div key={p.id} className="mb-0.5">
              <ProjectHeader name={p.name} expanded={false} hasUnread={p.hasUnread} />
            </div>
          ),
        )}
      </div>

      {/* bottom safe-area inset: AgentsView panel (when open) + TagFilterFooter */}
      <AnimatePresence initial={false}>
        {agentsOpen && (
          <motion.div
            key="agents-panel"
            initial={{ height: 0, opacity: 0 }}
            animate={{ height: 188, opacity: 1 }}
            exit={{ height: 0, opacity: 0 }}
            transition={{ duration: 0.24, ease: [0.22, 1, 0.36, 1] }}
            className="overflow-hidden"
          >
            <ActiveAgentsSidebarPanel />
          </motion.div>
        )}
      </AnimatePresence>
      <TagFilterFooter agentsOpen={agentsOpen} onAgentsToggle={onAgentsToggle} />
    </aside>
  );
}

// ─── sidebar — project header ────────────────────────────────────────────

function ProjectHeader({
  name,
  expanded,
  hasUnread,
}: {
  name: string;
  expanded: boolean;
  hasUnread?: boolean;
}) {
  return (
    <button
      type="button"
      className="group flex h-6 w-full cursor-pointer items-center gap-1.5 rounded px-1.5 text-ink-muted hover:bg-ink/[0.04]"
    >
      {hasUnread ? (
        <span className="text-[#FFA657]">
          <BellFill size={10} />
        </span>
      ) : expanded ? (
        <ChevronDown size={11} />
      ) : (
        <ChevronRight size={11} />
      )}
      <span className="text-[12.5px] font-medium text-ink">{name}</span>
      <span className="ml-auto flex items-center gap-px opacity-0 transition-opacity group-hover:opacity-100">
        <span
          aria-label="Add Worktree"
          className="grid h-5 w-5 cursor-pointer place-items-center rounded-full hover:bg-ink/[0.08]"
        >
          <Plus size={10} />
        </span>
        <span
          aria-label="Project options"
          className="grid h-5 w-5 cursor-pointer place-items-center rounded-full hover:bg-ink/[0.08]"
        >
          <Ellipsis size={11} />
        </span>
      </span>
    </button>
  );
}

// ─── sidebar — worktree row ──────────────────────────────────────────────

function WorktreeRowView({ row }: { row: RowData }) {
  const Icon = (() => {
    if (row.unreadBell) return BellFill;
    if (row.synthetic) return Folder;
    if (row.pr) return prIcon(row.pr.state);
    if (row.isDefault) return StarFill;
    return GitBranch;
  })();
  const iconColor = (() => {
    if (row.unreadBell) return "text-[#FFA657]";
    if (row.pr) return PR_TINT[row.pr.state];
    if (row.pinned || row.isDefault) return "text-[#FFA657]";
    return "text-ink-muted";
  })();
  const checks = row.pr?.checks;

  // Two-line layout when branch !== name. Most rows here have a branch
  // distinct from the name so this matches the typical visual rhythm.
  const showBranch = row.branch && row.branch !== row.name;

  return (
    <li>
      <button
        type="button"
        className={`group relative flex w-full cursor-pointer items-center gap-1.5 rounded px-1.5 py-1 ${
          row.active ? "bg-[#2C6BCB]/45 text-white" : "text-ink/90 hover:bg-ink/[0.05]"
        }`}
      >
        {/* leading icon (spinner when busy) */}
        <span className={`relative flex h-3.5 w-3.5 shrink-0 items-center justify-center ${iconColor}`}>
          {row.busy ? (
            <Spinner size={12} />
          ) : (
            <Icon size={14} />
          )}
          {checks && checks !== "none" && !row.busy && (
            <span className="absolute -bottom-0.5 -right-0.5">
              {checks === "passing" && (
                <span className="text-[#3FB950]">
                  <CheckCircleFill size={9} />
                </span>
              )}
              {checks === "failing" && (
                <span className="text-[#F85149]">
                  <XCircleFill size={9} />
                </span>
              )}
              {checks === "pending" && (
                <span className="text-[#D29922]">
                  <ClockCircleFill size={9} />
                </span>
              )}
            </span>
          )}
        </span>

        {/* identity */}
        <span className="flex min-w-0 flex-1 flex-col items-start">
          <span className="flex items-center gap-1">
            <span className={`truncate text-[12.5px] ${row.active ? "text-white" : "text-ink"}`}>
              {row.name}
            </span>
            {row.pinned && !row.isDefault && (
              <span className="text-[#FFA657]">
                <PinFill size={9} />
              </span>
            )}
          </span>
          {showBranch && (
            <span
              className={`truncate font-mono text-[10.5px] leading-tight ${
                row.active ? "text-white/70" : "text-ink-muted"
              }`}
            >
              {row.branch}
            </span>
          )}
        </span>

        {/* trailing: diff stats + PR pill */}
        <span className="ml-auto flex shrink-0 items-center gap-1">
          {row.diff && (
            <span
              className={`rounded border px-1 py-[1px] font-mono text-[9.5px] tabular-nums ${
                row.active
                  ? "border-white/30 text-white/85"
                  : "border-line/80 text-ink-muted"
              }`}
            >
              {row.active ? (
                <>
                  <span>+{row.diff.add}</span>
                  {row.diff.del > 0 && <span className="ml-1">−{row.diff.del}</span>}
                </>
              ) : (
                <>
                  <span className="text-[#3FB950]">+{row.diff.add}</span>
                  {row.diff.del > 0 && <span className="ml-1 text-[#F85149]">−{row.diff.del}</span>}
                </>
              )}
            </span>
          )}
          {row.pr && <PRBadgePill number={row.pr.number} state={row.pr.state} />}
        </span>
      </button>
    </li>
  );
}

// ─── sidebar — agents view panel ─────────────────────────────────────────

function ActiveAgentsSidebarPanel() {
  const order: AgentState[] = ["waitingForInput", "finished", "loading", "idle"];
  const sorted = [...AGENTS].sort((a, b) => order.indexOf(a.state) - order.indexOf(b.state));

  return (
    <div className="relative flex h-full flex-col overflow-hidden rounded-t-[10px] border-x border-t border-white/10 bg-[#1c1c1f]/95 backdrop-blur-xl">
      {/* resize handle strip */}
      <div className="group/handle grid h-2 cursor-row-resize place-items-center">
        <span className="h-[3px] w-9 rounded-full bg-white/15 opacity-0 transition-opacity group-hover/handle:opacity-100" />
      </div>
      {/* title row */}
      <div className="flex items-center gap-2 px-2.5 pb-1.5 pt-0.5">
        <span className="text-[11px] uppercase tracking-wider text-ink-muted">Agents View</span>
        <span className="font-mono text-[10.5px] text-ink-dim">({AGENTS.length})</span>
      </div>
      {/* rows */}
      <div className="flex-1 overflow-y-auto">
        {sorted.map((a) => (
          <AgentRow key={a.id} a={a} />
        ))}
      </div>
    </div>
  );
}

const AGENT_LOGO: Record<AgentKind, React.ComponentType<{ size?: number }>> = {
  "claude-code": AgentClaude,
  codex: AgentCodex,
  pi: AgentPi,
  opencode: AgentOpenCode,
};

const STATE_VERB: Record<AgentState, string> = {
  waitingForInput: "waiting",
  loading: "working",
  finished: "finished",
  idle: "idle",
};

function AgentRow({ a }: { a: AgentEntry }) {
  const Logo = AGENT_LOGO[a.kind];
  const focused = a.state === "loading"; // simulate the focused-pane row
  return (
    <button
      type="button"
      className={`flex w-full cursor-pointer items-center gap-2 px-2.5 py-1.5 text-left transition-colors ${
        focused ? "bg-white/[0.07]" : "hover:bg-white/[0.04]"
      }`}
    >
      <span
        className={`grid h-5 w-5 shrink-0 place-items-center ${
          focused ? "text-ink" : "text-ink-muted"
        }`}
      >
        <Logo size={18} />
      </span>
      <span className="flex min-w-0 flex-1 flex-col">
        <span
          className={`truncate text-[12px] leading-tight ${
            focused ? "font-semibold text-ink" : "text-ink"
          }`}
        >
          {a.worktree}
        </span>
        <span className="truncate text-[10.5px] leading-tight text-ink-muted">{a.project}</span>
      </span>
      <span className="flex shrink-0 items-center gap-1">
        <AgentStateIcon state={a.state} />
        <span
          className={`font-mono text-[10.5px] ${
            a.state === "waitingForInput"
              ? "text-[#FFA657]"
              : a.state === "finished"
                ? "text-[#3FB950]"
                : a.state === "loading"
                  ? "text-ink"
                  : "text-ink-muted"
          }`}
        >
          {STATE_VERB[a.state]}
        </span>
      </span>
    </button>
  );
}

function AgentStateIcon({ state }: { state: AgentState }) {
  switch (state) {
    case "waitingForInput":
      return (
        <span className="text-[#FFA657]">
          <PauseFill size={11} />
        </span>
      );
    case "loading":
      return (
        <span className="text-ink">
          <LoadingGrid size={11} />
        </span>
      );
    case "finished":
      return (
        <span className="text-[#3FB950]">
          <CheckCircleFill size={11} />
        </span>
      );
    case "idle":
      return (
        <span className="text-ink-muted">
          <CircleDashed size={11} />
        </span>
      );
  }
}

// ─── sidebar — tag filter footer ─────────────────────────────────────────

function TagFilterFooter({
  agentsOpen,
  onAgentsToggle,
}: {
  agentsOpen: boolean;
  onAgentsToggle: () => void;
}) {
  return (
    <div className="flex h-7 items-center border-t border-line/70 bg-[#161618] px-1.5">
      <FooterIcon ariaLabel="Sort projects" help="Sort projects">
        <svg width="11" height="11" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4">
          <path d="M5 3v10M3 5l2-2 2 2M11 13V3M9 11l2 2 2-2" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </FooterIcon>
      <div className="flex-1" />
      <FooterIcon
        ariaLabel={agentsOpen ? "Hide agents view" : "Show agents view"}
        help={agentsOpen ? "Hide agents view" : "Show agents view"}
        onClick={onAgentsToggle}
        active={agentsOpen}
      >
        <svg width="13" height="13" viewBox="0 0 16 16" fill={agentsOpen ? "currentColor" : "none"} stroke="currentColor" strokeWidth="1.3">
          {/* sparkles + rectangle stack */}
          <rect x="2.5" y="5.5" width="9" height="6" rx="1.4" />
          <path d="M4.5 7.5h5M4.5 9.5h3" stroke="#0a0a0c" strokeWidth={agentsOpen ? 1.2 : 0} />
          <path
            d="M12.5 3l.6 1.4L14.5 5l-1.4.6L12.5 7l-.6-1.4L10.5 5l1.4-.6z"
            fill="currentColor"
          />
        </svg>
      </FooterIcon>
      <FooterIcon ariaLabel="Refresh all projects" help="Refresh all projects">
        <svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.4">
          <path d="M13.5 8a5.5 5.5 0 11-1.7-3.9M13.5 3v3h-3" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </FooterIcon>
    </div>
  );
}

function FooterIcon({
  children,
  ariaLabel,
  help,
  onClick,
  active,
}: {
  children: React.ReactNode;
  ariaLabel: string;
  help: string;
  onClick?: () => void;
  active?: boolean;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      title={help}
      aria-label={ariaLabel}
      className={`grid h-6 w-6 cursor-pointer place-items-center rounded-md transition-colors ${
        active ? "text-leaf-100 bg-leaf-700/20" : "text-ink-muted hover:bg-ink/[0.06] hover:text-ink"
      }`}
    >
      {children}
    </button>
  );
}

// ─── detail (right column body) ──────────────────────────────────────────

function Detail() {
  return (
    <div className="flex flex-col bg-[#0a0a0c]">
      <TabBar />
      <PaneSplit />
    </div>
  );
}

function TabBar() {
  const tabs = [
    { id: "t1", title: "claude", active: false, busy: false, dot: false },
    { id: "t2", title: "tests", active: false, busy: true, dot: true },
    { id: "t3", title: "vite", active: true, busy: false, dot: false },
    { id: "t4", title: "git", active: false, busy: false, dot: false },
  ];
  return (
    <div className="flex h-9 items-end gap-0.5 border-b border-line/70 bg-[#0e0e11] px-2 pt-1">
      {tabs.map((t) => (
        <button
          key={t.id}
          type="button"
          className={`group flex h-[30px] min-w-[92px] cursor-pointer items-center gap-1.5 rounded-t-md border border-b-0 px-2.5 font-mono text-[11.5px] transition-colors ${
            t.active
              ? "border-line bg-[#181820] text-ink"
              : "border-transparent text-ink-muted hover:bg-ink/[0.04] hover:text-ink"
          }`}
        >
          {t.busy ? (
            <span className="text-leaf-300">
              <Spinner size={9} />
            </span>
          ) : (
            <span
              className={`h-1.5 w-1.5 rounded-full ${
                t.dot ? "bg-[#FFA657]" : t.active ? "bg-leaf-300" : "bg-ink-dim/50"
              }`}
            />
          )}
          <span className="truncate">{t.title}</span>
          <span className="ml-1 text-ink-dim opacity-0 transition-opacity group-hover:opacity-100">
            ×
          </span>
        </button>
      ))}
      <button
        type="button"
        aria-label="New tab"
        className="ml-1 grid h-6 w-6 cursor-pointer place-items-center rounded text-ink-muted hover:bg-ink/[0.05] hover:text-ink"
      >
        <Plus size={12} />
      </button>
      <span className="ml-auto flex items-center gap-1.5 px-2 font-mono text-[10.5px] text-ink-dim">
        <span className="h-1 w-1 rounded-full bg-leaf-300 animate-breathe" />
        connected · /tmp/touch-code.sock
      </span>
    </div>
  );
}

function PaneSplit() {
  return (
    <div className="grid flex-1 grid-cols-[1.25fr_1fr] gap-px bg-line/70">
      <PaneBody
        prompt="❯"
        lines={[
          "$ claude",
          "✦ Reading apps/mac/touch-code/App/Features/StatusBar/StatusBarFeature.swift",
          "✦ Drafting fix for slot priority resolution",
          "↳ Apply patch? [y/N]",
        ]}
        waitingPrompt
      />
      <PaneBody
        prompt="❯"
        lines={[
          "$ pnpm dev",
          "  ➜  Local:   http://127.0.0.1:5173/",
          "HMR update /src/sections/Hero.tsx",
          "HMR update /src/components/app/AppShell.tsx",
        ]}
      />
    </div>
  );
}

function PaneBody({
  prompt,
  lines,
  waitingPrompt,
}: {
  prompt: string;
  lines: string[];
  waitingPrompt?: boolean;
}) {
  return (
    <div className="relative bg-[#0a0a0c]">
      <div className="p-3 font-mono text-[11.5px] leading-[1.6] text-ink/85">
        {lines.map((l, i) => {
          const isPrompt = l.startsWith("$");
          return (
            <div key={i}>
              {isPrompt ? (
                <>
                  <span className="text-leaf-300">{prompt} </span>
                  <span className="text-ink">{l.slice(2)}</span>
                </>
              ) : (
                <span>{l}</span>
              )}
            </div>
          );
        })}
        {waitingPrompt && (
          <div className="mt-2 inline-flex items-center gap-1.5 rounded border border-[#FFA657]/40 bg-[#FFA657]/[0.06] px-1.5 py-1 text-[10.5px] text-[#FFA657]">
            <PauseFill size={9} />
            waiting for your input
          </div>
        )}
        <span className="ml-0.5 mt-0.5 inline-block h-[12px] w-[6px] bg-leaf-300 align-middle animate-blink" />
      </div>
    </div>
  );
}

// ─── overlays — notifications popover ───────────────────────────────────

function NotificationsPopover() {
  return (
    <motion.div
      initial={{ opacity: 0, y: -8, scale: 0.97 }}
      animate={{ opacity: 1, y: 0, scale: 1 }}
      exit={{ opacity: 0, y: -6, scale: 0.97 }}
      transition={{ duration: 0.2 }}
      className="absolute right-[170px] top-[44px] z-30 w-[360px] overflow-hidden rounded-xl border border-line/80 bg-[#1c1c1f]/95 shadow-2xl backdrop-blur-2xl"
    >
      {/* small arrow above the popover */}
      <span
        aria-hidden
        className="absolute -top-[5px] right-[42px] h-3 w-3 rotate-45 border-l border-t border-line/80 bg-[#1c1c1f]"
      />
      <div className="relative flex items-center justify-between border-b border-line/60 px-3 py-2 font-mono text-[11.5px]">
        <div className="flex h-6 overflow-hidden rounded-md border border-line text-[11px]">
          <button type="button" className="grid place-items-center bg-[#26262B] px-2 text-ink">
            Unread
          </button>
          <button type="button" className="grid place-items-center px-2 text-ink-muted hover:bg-ink/[0.04]">
            All
          </button>
        </div>
        <button type="button" className="text-[11px] text-ink-muted hover:text-ink">
          Mark all read
        </button>
      </div>
      <ul className="max-h-[280px] overflow-y-auto">
        {NOTIFICATIONS.map((n) => (
          <NotifRow key={n.id} n={n} />
        ))}
      </ul>
    </motion.div>
  );
}

function NotifRow({ n }: { n: NotificationItem }) {
  return (
    <li>
      <button
        type="button"
        className="flex w-full items-start gap-2.5 border-b border-line/40 px-3 py-2.5 text-left transition-colors hover:bg-ink/[0.04]"
      >
        <span
          className="mt-1 flex h-1.5 w-1.5 shrink-0 rounded-full bg-[#FFA657]"
          style={{ opacity: n.unread ? 1 : 0 }}
        />
        <span className="flex min-w-0 flex-1 flex-col">
          <span className="truncate font-mono text-[11px] text-ink-muted">
            {n.project} <span className="text-ink-dim">/</span> {n.worktree}
          </span>
          <span className="truncate text-[12px] text-ink">{n.body}</span>
        </span>
        <span className="shrink-0 font-mono text-[10.5px] text-ink-dim">{n.age}</span>
      </button>
    </li>
  );
}

// ─── overlays — command palette ─────────────────────────────────────────

function CommandPaletteOverlay() {
  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      transition={{ duration: 0.18 }}
      className="absolute inset-0 z-40 grid place-items-start bg-black/30 pt-14 backdrop-blur-[2px]"
    >
      <motion.div
        initial={{ y: -10, scale: 0.98, opacity: 0 }}
        animate={{ y: 0, scale: 1, opacity: 1 }}
        exit={{ y: -6, scale: 0.98, opacity: 0 }}
        transition={{ duration: 0.22, ease: [0.22, 1, 0.36, 1] }}
        className="mx-auto w-[560px] overflow-hidden rounded-xl border border-line/80 bg-[#1c1c1f]/95 shadow-2xl backdrop-blur-2xl"
      >
        <div className="flex h-12 items-center gap-2 border-b border-line/60 px-3.5 text-ink-muted">
          <Search size={14} />
          <input
            disabled
            value="open"
            className="flex-1 bg-transparent font-mono text-[14px] text-ink outline-none"
          />
          <span className="rounded border border-line px-1.5 font-mono text-[10px] text-ink-dim">
            ⎋ esc
          </span>
        </div>
        <ul className="max-h-[300px] overflow-y-auto p-1.5">
          {COMMANDS.slice(0, 6).map((c, i) => (
            <CommandRow key={c.id} c={c} selected={i === 1} />
          ))}
        </ul>
      </motion.div>
    </motion.div>
  );
}

function CommandRow({ c, selected }: { c: CommandItem; selected: boolean }) {
  const Icon = (() => {
    switch (c.icon) {
      case "plus":
        return Plus;
      case "branch":
        return GitBranch;
      case "book":
        return Book;
      case "openExt":
        return ArrowUpRight;
      case "gear":
        return Gear;
      case "search":
        return Search;
      case "folder":
        return Folder;
      case "bell":
        return Bell;
    }
  })();
  return (
    <li>
      <button
        type="button"
        className={`flex w-full items-center gap-2.5 rounded-md px-2.5 py-2 transition-colors ${
          selected ? "bg-[#2C6BCB] text-white" : "text-ink hover:bg-ink/[0.05]"
        }`}
      >
        <span className={`grid h-5 w-5 place-items-center ${selected ? "text-white" : "text-ink-muted"}`}>
          <Icon size={14} />
        </span>
        <span className="flex min-w-0 flex-1 flex-col text-left">
          <span className="truncate text-[13px]">{c.title}</span>
          {c.subtitle && (
            <span
              className={`truncate text-[11px] ${
                selected ? "text-white/80" : "text-ink-muted"
              }`}
            >
              {c.subtitle}
            </span>
          )}
        </span>
        {c.chord && (
          <span
            className={`font-mono text-[11px] ${
              selected ? "text-white/85" : "text-ink-muted"
            }`}
          >
            {c.chord}
          </span>
        )}
      </button>
    </li>
  );
}
