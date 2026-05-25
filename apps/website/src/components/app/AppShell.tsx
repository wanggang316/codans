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
  ConnectedNodes,
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

// ─── palette helpers ─────────────────────────────────────────────────────

const PR_TINT: Record<PrState, string> = {
  open: "text-[#3FB950]", // GitHub Primer "green/4"
  draft: "text-[#8B949E]",
  merged: "text-[#A371F7]",
  closed: "text-[#F85149]",
};

const PR_BADGE_BG: Record<PrState, string> = {
  open: "bg-[#1A4D2E] text-[#9BE6AE] border-[#2E7C44]",
  draft: "bg-[#21262D] text-[#B0B7BE] border-[#373E47]",
  merged: "bg-[#3B2A5C] text-[#D2B7FF] border-[#6E40C9]",
  closed: "bg-[#4A1F22] text-[#FFADAB] border-[#A6353B]",
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

// ─── outer window ────────────────────────────────────────────────────────

export default function AppShell() {
  const [overlay, setOverlay] = useState<"agents" | "bell" | "palette" | null>("agents");

  // Auto-rotate the floating overlays so the visitor sees Active Agents,
  // the Notification bell, and the Command Palette without interacting.
  useEffect(() => {
    const order: Array<typeof overlay> = ["agents", "bell", "palette", null];
    let i = 0;
    const tick = () => {
      i = (i + 1) % order.length;
      setOverlay(order[i]);
    };
    const id = window.setInterval(tick, 5200);
    return () => window.clearInterval(id);
  }, []);

  return (
    <div className="relative">
      <div className="relative overflow-hidden rounded-2xl border border-line bg-[#101013] shadow-window">
        <TitleBar />
        <div className="grid grid-cols-[244px_1fr] lg:grid-cols-[260px_1fr]">
          <Sidebar />
          <Detail overlay={overlay} setOverlay={setOverlay} />
        </div>
      </div>
    </div>
  );
}

// ─── title bar ───────────────────────────────────────────────────────────

function TitleBar() {
  return (
    <div className="flex h-9 items-center gap-3 border-b border-line/80 bg-[#0d0d10] px-4">
      <div className="flex gap-1.5">
        <span className="h-3 w-3 rounded-full bg-[#ff5f57]" />
        <span className="h-3 w-3 rounded-full bg-[#febc2e]" />
        <span className="h-3 w-3 rounded-full bg-[#28c840]" />
      </div>
      <div className="flex-1 text-center font-mono text-[12px] text-ink-muted">
        <span className="text-ink/80">touch-code</span>
        <span className="mx-2 text-ink-dim">—</span>
        <span>feat/agent-loop</span>
      </div>
      <div className="w-[58px]" />
    </div>
  );
}

// ─── sidebar ─────────────────────────────────────────────────────────────

function Sidebar() {
  return (
    <aside className="flex h-[560px] flex-col border-r border-line/80 bg-[#0c0c0f]">
      {/* sidebar toolbar */}
      <div className="flex h-9 items-center justify-between border-b border-line/60 px-2.5 text-[12px] text-ink-muted">
        <button className="flex items-center gap-1.5 rounded px-1.5 py-1 hover:bg-ink/[0.04] hover:text-ink">
          <Plus size={11} /> Add Project
        </button>
        <button className="flex h-6 w-6 items-center justify-center rounded text-ink-muted hover:bg-ink/[0.04] hover:text-ink">
          <Ellipsis size={14} />
        </button>
      </div>

      <div className="flex-1 overflow-hidden px-1.5 py-2 font-mono text-[12px]">
        {PROJECTS.map((p) =>
          p.expanded ? (
            <div key={p.id} className="mb-1">
              <ProjectHeader name={p.name} expanded hasUnread={p.hasUnread} />
              <ul className="mt-0.5 space-y-px">
                {p.worktrees.map((w) => (
                  <li key={w.id}>
                    <WorktreeRowView row={w} />
                  </li>
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

      {/* space footer */}
      <div className="border-t border-line/60 px-2 py-2">
        <button className="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-[12px] text-ink hover:bg-ink/[0.04]">
          <span className="grid h-5 w-5 place-items-center rounded bg-leaf-700/30 text-leaf-100">🗂</span>
          <span className="font-mono">Work</span>
          <span className="ml-auto text-ink-dim">
            <CaretDown size={11} />
          </span>
        </button>
      </div>
    </aside>
  );
}

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
    <div className="group flex h-6 items-center gap-1.5 rounded px-1.5 text-ink-muted hover:bg-ink/[0.03]">
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
      <span className="ml-auto flex items-center opacity-0 transition-opacity group-hover:opacity-100">
        <button className="grid h-5 w-5 place-items-center rounded text-ink-muted hover:bg-ink/[0.06]">
          <Plus size={10} />
        </button>
        <button className="grid h-5 w-5 place-items-center rounded text-ink-muted hover:bg-ink/[0.06]">
          <Ellipsis size={11} />
        </button>
      </span>
    </div>
  );
}

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

  return (
    <div
      className={`group relative flex h-7 items-center gap-1.5 rounded px-1.5 ${
        row.active ? "bg-[#1F4D8B]/55 text-white" : "text-ink/90 hover:bg-ink/[0.04]"
      }`}
    >
      {/* leading icon (or spinner when busy) */}
      <span className={`relative flex h-3.5 w-3.5 items-center justify-center ${iconColor}`}>
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

      <span className="flex min-w-0 flex-1 items-center gap-1">
        <span className={`truncate ${row.active ? "text-white" : "text-ink"}`}>{row.name}</span>
        {row.pinned && !row.isDefault && (
          <span className="text-[#FFA657]">
            <PinFill size={9} />
          </span>
        )}
      </span>

      {/* trailing: diff stats / PR pill / chord hint */}
      <span className="ml-auto flex items-center gap-1">
        {row.diff && (
          <span className="rounded border border-line/80 px-1 py-[1px] font-mono text-[9.5px] tabular-nums">
            <span className="text-[#3FB950]">+{row.diff.add}</span>
            {row.diff.del > 0 && <span className="ml-1 text-[#F85149]">−{row.diff.del}</span>}
          </span>
        )}
        {row.pr && <PRBadgePill number={row.pr.number} state={row.pr.state} />}
      </span>
    </div>
  );
}

function PRBadgePill({ number, state }: { number: number; state: PrState }) {
  return (
    <span
      className={`inline-flex items-center gap-1 rounded border px-1.5 py-[1px] font-mono text-[9.5px] tabular-nums ${PR_BADGE_BG[state]}`}
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

// ─── detail (header + tabbar + panes) ────────────────────────────────────

function Detail({
  overlay,
  setOverlay,
}: {
  overlay: "agents" | "bell" | "palette" | null;
  setOverlay: (o: "agents" | "bell" | "palette" | null) => void;
}) {
  return (
    <div className="relative flex h-[560px] flex-col">
      <Header overlay={overlay} setOverlay={setOverlay} />
      <TabBar />
      <PaneSplit />

      {/* Floating overlays */}
      <AnimatePresence>
        {overlay === "agents" && <ActiveAgentsPopover key="agents" />}
        {overlay === "bell" && <NotificationsPopover key="bell" />}
        {overlay === "palette" && <CommandPaletteOverlay key="palette" />}
      </AnimatePresence>
    </div>
  );
}

// ─── header ──────────────────────────────────────────────────────────────

function Header({
  overlay,
  setOverlay,
}: {
  overlay: "agents" | "bell" | "palette" | null;
  setOverlay: (o: "agents" | "bell" | "palette" | null) => void;
}) {
  return (
    <div className="relative flex h-11 items-center gap-3 border-b border-line/70 bg-[#0e0e11] px-4">
      {/* left: branch */}
      <div className="flex shrink-0 items-center gap-1.5 font-mono text-[12.5px] text-ink-muted">
        <span className="text-ink-dim">
          <ConnectedNodes size={13} />
        </span>
        <span className="text-ink">feat/agent-loop</span>
      </div>

      {/* flexible spacer */}
      <div className="flex-1" />

      {/* center: status slot — lives between two flex spacers so it auto-centers
          between the left and right clusters without colliding when the right
          cluster grows. */}
      <StatusSlot />

      <div className="flex-1" />

      {/* right: active-agents pill, bell, open-in split, git viewer, settings */}
      <div className="flex shrink-0 items-center gap-1">
        <ActiveAgentsPill
          highlighted={overlay === "agents"}
          onClick={() => setOverlay(overlay === "agents" ? null : "agents")}
        />
        <HeaderButton
          onClick={() => setOverlay(overlay === "bell" ? null : "bell")}
          ariaLabel="Notifications"
          highlighted={overlay === "bell"}
        >
          <span className="relative inline-flex items-center">
            <span className="text-[#FFA657]">
              <BellFill size={15} />
            </span>
            <span className="ml-1 font-mono text-[11px] font-semibold tabular-nums text-ink">3</span>
          </span>
        </HeaderButton>
        <SplitButton />
        <HeaderButton ariaLabel="Git Viewer">
          <Book size={15} />
        </HeaderButton>
        <HeaderButton ariaLabel="Settings">
          <Gear size={15} />
        </HeaderButton>
      </div>
    </div>
  );
}

function HeaderButton({
  children,
  onClick,
  ariaLabel,
  highlighted,
}: {
  children: React.ReactNode;
  onClick?: () => void;
  ariaLabel?: string;
  highlighted?: boolean;
}) {
  return (
    <button
      onClick={onClick}
      aria-label={ariaLabel}
      className={`grid h-7 min-w-[28px] place-items-center rounded px-1.5 text-ink-muted transition-colors ${
        highlighted ? "bg-ink/10 text-ink" : "hover:bg-ink/[0.06] hover:text-ink"
      }`}
    >
      {children}
    </button>
  );
}

function SplitButton() {
  return (
    <div className="ml-1 flex items-center overflow-hidden rounded border border-line/80 bg-[#15151a]">
      <button className="flex h-7 items-center gap-1.5 px-2 text-[12px] text-ink hover:bg-ink/[0.05]">
        <ArrowUpRight size={13} />
        <span>Open in</span>
      </button>
      <span className="h-3.5 w-px bg-line" />
      <button className="grid h-7 w-6 place-items-center text-ink-muted hover:bg-ink/[0.05] hover:text-ink">
        <CaretDown size={11} />
      </button>
    </div>
  );
}

// ─── status slot ─────────────────────────────────────────────────────────

function StatusSlot() {
  // Cycle: PR → inProgress → success → motivational → PR
  const states = ["pr", "inProgress", "success", "motivational"] as const;
  type S = (typeof states)[number];
  const [i, setI] = useState(0);
  useEffect(() => {
    const id = window.setInterval(() => setI((n) => (n + 1) % states.length), 3800);
    return () => window.clearInterval(id);
  }, []);
  const s: S = states[i];

  return (
    <div className="relative h-7 w-[260px] overflow-visible">
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

// ─── active-agents pill (right-side, inline in header) ──────────────────

function ActiveAgentsPill({
  highlighted,
  onClick,
}: {
  highlighted?: boolean;
  onClick?: () => void;
}) {
  // Mixed-state headline per spec: "1 waiting · 2 working"
  return (
    <button
      onClick={onClick}
      className={`flex h-7 items-center gap-1.5 rounded border border-line/80 px-2 text-[12px] transition-colors ${
        highlighted ? "border-leaf-500/60 bg-leaf-700/15 text-leaf-50" : "bg-[#15151a] text-ink hover:bg-ink/[0.05]"
      }`}
    >
      <span className="relative flex h-3.5 w-3.5 items-center justify-center">
        <span className="text-[#FFA657]">
          <PauseFill size={10} />
        </span>
        <motion.span
          aria-hidden
          animate={{ opacity: [0.0, 0.6, 0.0] }}
          transition={{ duration: 1.8, repeat: Infinity }}
          className="absolute inset-[-2px] rounded-full bg-[#FFA657]/30"
        />
      </span>
      <span className="font-mono">
        <span className="text-[#FFA657]">1 waiting</span>
        <span className="mx-1 text-ink-dim">·</span>
        <span>2 working</span>
      </span>
    </button>
  );
}

// ─── tab bar ─────────────────────────────────────────────────────────────

function TabBar() {
  const tabs = [
    { id: "t1", title: "claude", active: false, busy: false, dot: false },
    { id: "t2", title: "tests", active: false, busy: true, dot: true },
    { id: "t3", title: "vite", active: true, busy: false, dot: false },
    { id: "t4", title: "git", active: false, busy: false, dot: false },
  ];
  return (
    <div className="flex h-[34px] items-end gap-0.5 border-b border-line/70 bg-[#0c0c0f] px-2 pt-1">
      {tabs.map((t) => (
        <button
          key={t.id}
          className={`group flex h-[28px] min-w-[88px] items-center gap-1.5 rounded-t-md border border-b-0 px-2.5 font-mono text-[11.5px] ${
            t.active
              ? "border-line bg-[#15151a] text-ink"
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
      {/* trailing accessory cluster */}
      <span className="ml-1 flex items-center gap-0.5 text-ink-dim">
        <button className="grid h-6 w-6 place-items-center rounded hover:bg-ink/[0.05] hover:text-ink">
          <Plus size={12} />
        </button>
      </span>
      <span className="ml-auto flex items-center gap-1 px-2 font-mono text-[10.5px] text-ink-dim">
        <span className="h-1 w-1 rounded-full bg-leaf-300 animate-breathe" />
        connected
      </span>
    </div>
  );
}

// ─── panes ───────────────────────────────────────────────────────────────

function PaneSplit() {
  return (
    <div className="grid flex-1 grid-cols-[1.3fr_1fr] gap-[1px] bg-line/70">
      <PaneBody
        prompt="❯"
        agent={{ kind: "claude-code", name: "claude" }}
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
        agent={{ kind: "codex", name: "codex" }}
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
  agent: { kind: AgentKind; name: string };
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
          <div className="mt-2 flex items-center gap-1.5 rounded border border-[#FFA657]/40 bg-[#FFA657]/[0.05] px-1.5 py-1 text-[10.5px] text-[#FFA657]">
            <PauseFill size={9} />
            waiting for your input
          </div>
        )}
        <span className="ml-0.5 mt-0.5 inline-block h-[12px] w-[6px] bg-leaf-300 align-middle animate-blink" />
      </div>
    </div>
  );
}

// ─── overlays: active agents popover ────────────────────────────────────

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

function ActiveAgentsPopover() {
  const order: AgentState[] = ["waitingForInput", "finished", "loading", "idle"];
  const sorted = [...AGENTS].sort((a, b) => order.indexOf(a.state) - order.indexOf(b.state));
  return (
    <motion.div
      initial={{ opacity: 0, y: -8, scale: 0.97 }}
      animate={{ opacity: 1, y: 0, scale: 1 }}
      exit={{ opacity: 0, y: -6, scale: 0.97 }}
      transition={{ duration: 0.22, ease: [0.22, 1, 0.36, 1] }}
      className="absolute right-[210px] top-[44px] z-30 w-[320px] overflow-hidden rounded-lg border border-line/80 bg-[#15151a]/95 shadow-2xl backdrop-blur-xl"
    >
      <div className="border-b border-line/60 px-3 py-2 font-mono text-[12px] text-ink-muted">
        Active Agents <span className="text-ink">({AGENTS.length})</span>
      </div>
      <ul>
        {sorted.map((a) => (
          <AgentRow key={a.id} a={a} />
        ))}
      </ul>
    </motion.div>
  );
}

function AgentRow({ a }: { a: AgentEntry }) {
  const Logo = AGENT_LOGO[a.kind];
  return (
    <li className="flex items-center gap-2.5 px-3 py-2 hover:bg-ink/[0.04]">
      <span className="grid h-6 w-6 place-items-center text-ink-muted">
        <Logo size={20} />
      </span>
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="truncate font-mono text-[12px] text-ink">{a.worktree}</span>
        <span className="truncate font-mono text-[11px] text-ink-muted">{a.project}</span>
      </span>
      <span className="flex items-center gap-1.5 text-[11px] font-mono">
        <AgentStateIcon state={a.state} />
        <span
          className={
            a.state === "waitingForInput"
              ? "text-[#FFA657]"
              : a.state === "finished"
                ? "text-[#3FB950]"
                : a.state === "loading"
                  ? "text-ink"
                  : "text-ink-muted"
          }
        >
          {STATE_VERB[a.state]}
        </span>
      </span>
    </li>
  );
}

function AgentStateIcon({ state }: { state: AgentState }) {
  switch (state) {
    case "waitingForInput":
      return (
        <span className="text-[#FFA657]">
          <PauseFill size={12} />
        </span>
      );
    case "loading":
      return (
        <span className="text-ink">
          <LoadingGrid size={12} />
        </span>
      );
    case "finished":
      return (
        <span className="text-[#3FB950]">
          <CheckCircleFill size={12} />
        </span>
      );
    case "idle":
      return (
        <span className="text-ink-muted">
          <CircleDashed size={12} />
        </span>
      );
  }
}

// ─── overlays: notifications popover ────────────────────────────────────

function NotificationsPopover() {
  return (
    <motion.div
      initial={{ opacity: 0, y: -8, scale: 0.97 }}
      animate={{ opacity: 1, y: 0, scale: 1 }}
      exit={{ opacity: 0, y: -6, scale: 0.97 }}
      transition={{ duration: 0.22 }}
      className="absolute right-[150px] top-[44px] z-30 w-[360px] overflow-hidden rounded-lg border border-line/80 bg-[#15151a]/95 shadow-2xl backdrop-blur-xl"
    >
      <div className="flex items-center justify-between border-b border-line/60 px-3 py-2 font-mono text-[11.5px]">
        <div className="flex h-6 overflow-hidden rounded-md border border-line text-[11px]">
          <span className="grid place-items-center bg-[#1F1F22] px-2 text-ink">Unread</span>
          <span className="grid place-items-center px-2 text-ink-muted">All</span>
        </div>
        <button className="text-[11px] text-ink-muted hover:text-ink">Mark all read</button>
      </div>
      <ul>
        {NOTIFICATIONS.map((n) => (
          <NotifRow key={n.id} n={n} />
        ))}
      </ul>
    </motion.div>
  );
}

function NotifRow({ n }: { n: NotificationItem }) {
  return (
    <li className="flex items-start gap-2.5 border-b border-line/40 px-3 py-2.5 hover:bg-ink/[0.04]">
      <span className="mt-1 flex h-1.5 w-1.5 shrink-0 rounded-full bg-[#FFA657]" style={{ opacity: n.unread ? 1 : 0 }} />
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="truncate font-mono text-[11px] text-ink-muted">
          {n.project} <span className="text-ink-dim">/</span> {n.worktree}
        </span>
        <span className="truncate text-[12px] text-ink">{n.body}</span>
      </span>
      <span className="shrink-0 font-mono text-[10.5px] text-ink-dim">{n.age}</span>
    </li>
  );
}

// ─── overlays: command palette ──────────────────────────────────────────

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
        className="w-[560px] overflow-hidden rounded-xl border border-line/80 bg-[#15151a]/95 shadow-2xl backdrop-blur-xl"
      >
        <div className="flex h-12 items-center gap-2 border-b border-line/60 px-3.5 text-ink-muted">
          <Search size={14} />
          <input
            disabled
            value="open"
            className="flex-1 bg-transparent font-mono text-[14px] text-ink outline-none"
          />
          <span className="rounded border border-line px-1.5 font-mono text-[10px] text-ink-dim">⎋ esc</span>
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
    <li
      className={`flex items-center gap-2.5 rounded-md px-2.5 py-2 ${
        selected ? "bg-[#1F4D8B] text-white" : "text-ink hover:bg-ink/[0.04]"
      }`}
    >
      <span className={`grid h-5 w-5 place-items-center ${selected ? "text-white" : "text-ink-muted"}`}>
        <Icon size={14} />
      </span>
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="truncate text-[13px]">{c.title}</span>
        {c.subtitle && (
          <span className={`truncate text-[11px] ${selected ? "text-white/80" : "text-ink-muted"}`}>
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
    </li>
  );
}
