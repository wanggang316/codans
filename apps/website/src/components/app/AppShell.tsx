import { useEffect, useRef, useState } from "react";
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
  DETAIL,
  EDITOR_CHOICES,
  EditorChoice,
  NOTIFICATIONS,
  NotificationItem,
  PROJECTS,
  PaneConfig,
  PrState,
  RUN_SCRIPTS,
  RunScript,
  StatusForm,
  TabConfig,
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

const SIDEBAR_W = 264;
const WINDOW_R = 14;

// Shared "glass" treatment for sidebar + titlebar — a translucent tint
// over the desktop backdrop with heavy backdrop blur, a hairline highlight
// at the top edge, and a faint inner shadow at the bottom. Mirrors the
// macOS 26 (Tahoe) Liquid Glass material.
const GLASS =
  "bg-white/[0.04] backdrop-blur-2xl backdrop-saturate-150 " +
  "shadow-[inset_0_1px_0_rgba(255,255,255,0.06),inset_0_-1px_0_rgba(0,0,0,0.4)]";

// ─── outer shell ─────────────────────────────────────────────────────────

type MenuKind = "bell" | "open-in" | "run" | "palette" | null;

export default function AppShell() {
  const [selected, setSelected] = useState<string>("feat-agent-loop");
  const [agentsOpen, setAgentsOpen] = useState(true);
  const [menu, setMenu] = useState<MenuKind>(null);

  // Esc dismisses whatever menu / overlay is currently open.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setMenu(null);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const detail = DETAIL[selected] ?? DETAIL["main"];
  const defaultEditor: EditorChoice =
    EDITOR_CHOICES.find((e) => e.id === "vscode") ?? EDITOR_CHOICES[0];

  return (
    <div className="relative">
      <div
        className="relative overflow-hidden border border-white/[0.08] shadow-window"
        style={{ borderRadius: WINDOW_R }}
      >
        {/* Desktop tint behind the glass: a faint diagonal radial that gives
            the sidebar / titlebar something to refract. Soft enough that the
            content reads as primary, but visible enough that the glass
            material actually shows. */}
        <DesktopTint />

        <TitleBar
          selected={selected}
          detail={detail}
          defaultEditor={defaultEditor}
          menu={menu}
          setMenu={setMenu}
        />
        <div
          className="relative grid h-[560px]"
          style={{ gridTemplateColumns: `${SIDEBAR_W}px 1fr` }}
        >
          <Sidebar
            selected={selected}
            onSelect={(id) => {
              setSelected(id);
              setMenu(null);
            }}
            agentsOpen={agentsOpen}
            onAgentsToggle={() => setAgentsOpen((o) => !o)}
          />
          <Detail detail={detail} />
        </div>

        {/* All overlay surfaces live at the AppShell root with z-50 — that
            way they always paint above the title bar grid + body grid
            instead of getting trapped in the titlebar's stacking
            context. Anchored via absolute coords relative to AppShell. */}
        <AnimatePresence>
          {menu === "bell" && (
            <NotificationsPopover key="bell" onDismiss={() => setMenu(null)} />
          )}
          {menu === "open-in" && (
            <OpenInMenu key="open-in" onDismiss={() => setMenu(null)} />
          )}
          {menu === "run" && <RunScriptMenu key="run" onDismiss={() => setMenu(null)} />}
          {menu === "palette" && (
            <CommandPaletteOverlay key="palette" onDismiss={() => setMenu(null)} />
          )}
        </AnimatePresence>
      </div>
    </div>
  );
}

function DesktopTint() {
  return (
    <div
      aria-hidden
      className="pointer-events-none absolute inset-0 -z-0"
      style={{
        background:
          "radial-gradient(900px 480px at 22% 0%, rgba(132,173,64,0.12), transparent 55%), " +
          "radial-gradient(700px 420px at 90% 100%, rgba(85,108,255,0.10), transparent 60%), " +
          "linear-gradient(180deg, #0c0c10 0%, #0a0a0c 100%)",
      }}
    />
  );
}

// ─── titlebar — spans whole window ───────────────────────────────────────

function TitleBar({
  selected,
  detail,
  defaultEditor,
  menu,
  setMenu,
}: {
  selected: string;
  detail: { branchLabel: string; status: StatusForm };
  defaultEditor: EditorChoice;
  menu: MenuKind;
  setMenu: (m: MenuKind) => void;
}) {
  const w = PROJECTS[0].worktrees.find((x) => x.id === selected);

  return (
    <div
      className={`relative grid h-11 items-center border-b border-white/[0.06] ${GLASS}`}
      style={{ gridTemplateColumns: `${SIDEBAR_W}px 1fr` }}
    >
      {/* sidebar half */}
      <div className="flex h-full items-center gap-2 px-3">
        <div className="flex shrink-0 gap-1.5">
          <TrafficLight color="#ff5f57" label="Close" />
          <TrafficLight color="#febc2e" label="Minimize" />
          <TrafficLight color="#28c840" label="Zoom" />
        </div>
        <div className="flex-1" />
        <ToolbarChip ariaLabel="Add Project" help="Add Project (⌘⇧N)">
          <Plus size={12} />
          <span className="ml-1 text-[12px]">Add Project</span>
        </ToolbarChip>
      </div>

      {/* hairline column divider */}
      <span
        aria-hidden
        className="absolute top-2 bottom-2 w-px bg-white/[0.08]"
        style={{ left: SIDEBAR_W - 0.5 }}
      />

      {/* detail half */}
      <div className="relative flex h-full items-center gap-2 px-3">
        <BranchIdentityChip row={w} branchLabel={detail.branchLabel} />
        <div className="flex-1" />
        <StatusSlotView form={detail.status} />
        <BellChip
          active={menu === "bell"}
          onClick={() => setMenu(menu === "bell" ? null : "bell")}
        />
        <div className="flex-1" />
        <RunScriptSplitButton
          menuOpen={menu === "run"}
          onCaret={() => setMenu(menu === "run" ? null : "run")}
        />
        <OpenInSplitButton
          editor={defaultEditor}
          menuOpen={menu === "open-in"}
          onCaret={() => setMenu(menu === "open-in" ? null : "open-in")}
        />
        <ToolbarChip ariaLabel="Settings" help="Settings (⌘,)">
          <Gear size={14} />
        </ToolbarChip>
      </div>
    </div>
  );
}

function TrafficLight({ color, label }: { color: string; label: string }) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      className="grid h-3 w-3 cursor-pointer place-items-center rounded-full transition hover:brightness-110 active:brightness-90"
      style={{ background: color }}
    />
  );
}

/**
 * macOS 26-style toolbar chip. A pill-shaped translucent surface with a
 * faint top highlight and dynamic hover wash.
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
      className={`inline-flex h-7 cursor-pointer items-center gap-1 rounded-[7px] border px-2 text-ink/90 transition-colors ${
        active
          ? "border-leaf-500/50 bg-leaf-700/15 text-leaf-50"
          : "border-white/[0.08] bg-white/[0.06] hover:bg-white/[0.10]"
      } shadow-[inset_0_1px_0_rgba(255,255,255,0.06)] focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-leaf-300/60 ${className}`}
    >
      {children}
    </button>
  );
}

function BranchIdentityChip({ row, branchLabel }: { row?: RowData; branchLabel: string }) {
  const Icon = (() => {
    if (!row) return GitBranch;
    if (row.unreadBell) return BellFill;
    if (row.synthetic) return Folder;
    if (row.pr) return prIcon(row.pr.state);
    if (row.isDefault) return StarFill;
    return GitBranch;
  })();
  const iconColor = (() => {
    if (!row) return "text-ink-muted";
    if (row.unreadBell) return "text-[#FFA657]";
    if (row.pr) return PR_TINT[row.pr.state];
    if (row.pinned || row.isDefault) return "text-[#FFA657]";
    return "text-ink-muted";
  })();
  const checks = row?.pr?.checks;
  return (
    <div className="group flex h-8 items-center gap-2 rounded-[7px] px-1.5 text-ink">
      <span className={`relative grid h-[18px] w-[18px] place-items-center ${iconColor}`}>
        <Icon size={16} />
        {checks && checks !== "none" && (
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
      <span className="flex flex-col">
        <span className="text-[12.5px] font-semibold leading-none">{branchLabel}</span>
        <span className="mt-0.5 font-mono text-[10.5px] leading-none text-ink-muted">
          touch-code
        </span>
      </span>
    </div>
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

function RunScriptSplitButton({
  menuOpen,
  onCaret,
}: {
  menuOpen?: boolean;
  onCaret: () => void;
}) {
  return (
    <div
      className={`flex h-7 overflow-hidden rounded-[7px] border bg-white/[0.06] shadow-[inset_0_1px_0_rgba(255,255,255,0.06)] ${
        menuOpen ? "border-leaf-500/50" : "border-white/[0.08]"
      }`}
    >
      <button
        type="button"
        title="Run setup.sh (⌘R)"
        className="flex cursor-pointer items-center gap-1.5 px-2 text-[12px] text-ink hover:bg-white/[0.06]"
      >
        <svg width="11" height="11" viewBox="0 0 16 16" fill="currentColor" className="text-leaf-300">
          <path d="M4 3l9 5-9 5V3z" />
        </svg>
        <span>Run</span>
      </button>
      <span className="w-px self-stretch bg-white/[0.08]" />
      <button
        type="button"
        aria-label="Choose script"
        title="Choose script"
        onClick={onCaret}
        className="grid w-6 cursor-pointer place-items-center text-ink-muted hover:bg-white/[0.06] hover:text-ink"
      >
        <CaretDown size={10} />
      </button>
    </div>
  );
}

function OpenInSplitButton({
  editor,
  menuOpen,
  onCaret,
}: {
  editor: EditorChoice;
  menuOpen?: boolean;
  onCaret: () => void;
}) {
  return (
    <div
      className={`flex h-7 overflow-hidden rounded-[7px] border bg-white/[0.06] shadow-[inset_0_1px_0_rgba(255,255,255,0.06)] ${
        menuOpen ? "border-leaf-500/50" : "border-white/[0.08]"
      }`}
    >
      <button
        type="button"
        title={`Open in ${editor.name} (${editor.chord ?? ""})`}
        className="flex cursor-pointer items-center gap-1.5 px-2 text-[12px] text-ink hover:bg-white/[0.06]"
      >
        <EditorGlyph id={editor.id} />
        <span>Open in {editor.name}</span>
      </button>
      <span className="w-px self-stretch bg-white/[0.08]" />
      <button
        type="button"
        aria-label="Choose editor"
        title="Choose editor"
        onClick={onCaret}
        className="grid w-6 cursor-pointer place-items-center text-ink-muted hover:bg-white/[0.06] hover:text-ink"
      >
        <CaretDown size={10} />
      </button>
    </div>
  );
}

/** Generic editor glyph — abstract letter chip, sized to feel like an app-mark. */
function EditorGlyph({ id }: { id: string }) {
  const map: Record<string, { letter: string; bg: string; fg: string }> = {
    vscode: { letter: "V", bg: "#007ACC", fg: "#ffffff" },
    cursor: { letter: "C", bg: "#1f1f24", fg: "#E8E8EA" },
    zed: { letter: "Z", bg: "#10131B", fg: "#FFE8B7" },
    xcode: { letter: "Xc", bg: "#147EFB", fg: "#ffffff" },
    sublime: { letter: "S", bg: "#1A1B22", fg: "#FE7B11" },
  };
  const m = map[id] ?? { letter: "?", bg: "#444", fg: "#fff" };
  return (
    <span
      className="grid h-[14px] w-[14px] place-items-center rounded-[3px] text-[8px] font-bold"
      style={{ background: m.bg, color: m.fg }}
      aria-hidden
    >
      {m.letter}
    </span>
  );
}

// ─── status slot ─────────────────────────────────────────────────────────

function StatusSlotView({ form }: { form: StatusForm }) {
  return (
    <div className="relative h-7 w-[240px] overflow-visible rounded-[7px] border border-white/[0.08] bg-white/[0.04] shadow-[inset_0_1px_0_rgba(255,255,255,0.04)]">
      <AnimatePresence mode="wait">
        <motion.div
          key={statusKey(form)}
          initial={{ opacity: 0, y: 4 }}
          animate={{ opacity: 1, y: 0 }}
          exit={{ opacity: 0, y: -4 }}
          transition={{ duration: 0.2, ease: "easeInOut" }}
          className="absolute inset-0 flex items-center justify-center gap-2"
        >
          {form.kind === "pr" && (
            <>
              <ChecksRing passing={form.passing} failing={form.failing} pending={form.pending} />
              <span className="font-mono text-[11.5px] text-ink-muted">{form.summary}</span>
            </>
          )}
          {form.kind === "inProgress" && (
            <>
              <Spinner size={11} />
              <span className="font-mono text-[11.5px] text-ink-muted">{form.message}</span>
            </>
          )}
          {form.kind === "success" && (
            <>
              <span className="text-[#3FB950]">
                <CheckCircleFill size={13} />
              </span>
              <span className="font-mono text-[11.5px] text-ink-muted">{form.message}</span>
            </>
          )}
          {form.kind === "warning" && (
            <>
              <span className="text-[#FFA657]">▲</span>
              <span className="font-mono text-[11.5px] text-ink-muted">{form.message}</span>
            </>
          )}
          {form.kind === "motivational" && (
            <>
              <span aria-hidden>🌇</span>
              <span className="font-mono text-[11.5px] text-ink-muted">
                17:42 · <span className="text-ink">⌘P</span> Command Palette
              </span>
            </>
          )}
        </motion.div>
      </AnimatePresence>
    </div>
  );
}

function statusKey(form: StatusForm): string {
  switch (form.kind) {
    case "pr":
      return `pr-${form.passing}-${form.failing}-${form.pending}`;
    case "inProgress":
    case "success":
    case "warning":
      return `${form.kind}-${form.message}`;
    case "motivational":
      return "mv";
  }
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
  selected,
  onSelect,
  agentsOpen,
  onAgentsToggle,
}: {
  selected: string;
  onSelect: (id: string) => void;
  agentsOpen: boolean;
  onAgentsToggle: () => void;
}) {
  return (
    <aside className={`relative flex flex-col border-r border-white/[0.06] ${GLASS}`}>
      {/* list */}
      <div className="flex-1 overflow-y-auto px-1.5 py-1.5">
        {PROJECTS.map((p) =>
          p.expanded ? (
            <div key={p.id} className="mb-1">
              <ProjectHeader name={p.name} expanded hasUnread={p.hasUnread} />
              <ul className="mt-0.5 space-y-px">
                {p.worktrees.map((w) => (
                  <WorktreeRowView
                    key={w.id}
                    row={w}
                    isSelected={w.id === selected}
                    onClick={() => onSelect(w.id)}
                  />
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

      {/* bottom safe-area inset */}
      <AnimatePresence initial={false}>
        {agentsOpen && (
          <motion.div
            key="agents-panel"
            initial={{ height: 0, opacity: 0 }}
            animate={{ height: 196, opacity: 1 }}
            exit={{ height: 0, opacity: 0 }}
            transition={{ duration: 0.24, ease: [0.22, 1, 0.36, 1] }}
            className="overflow-hidden"
          >
            <ActiveAgentsSidebarPanel onSelect={onSelect} selected={selected} />
          </motion.div>
        )}
      </AnimatePresence>
      <TagFilterFooter agentsOpen={agentsOpen} onAgentsToggle={onAgentsToggle} />
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
    <button
      type="button"
      className="group flex h-6 w-full cursor-pointer items-center gap-1.5 rounded px-1.5 text-ink-muted hover:bg-white/[0.04]"
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
          className="grid h-5 w-5 cursor-pointer place-items-center rounded-full hover:bg-white/[0.08]"
        >
          <Plus size={10} />
        </span>
        <span
          aria-label="Project options"
          className="grid h-5 w-5 cursor-pointer place-items-center rounded-full hover:bg-white/[0.08]"
        >
          <Ellipsis size={11} />
        </span>
      </span>
    </button>
  );
}

function WorktreeRowView({
  row,
  isSelected,
  onClick,
}: {
  row: RowData;
  isSelected: boolean;
  onClick: () => void;
}) {
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
  const showBranch = row.branch && row.branch !== row.name;

  return (
    <li>
      <button
        type="button"
        onClick={onClick}
        className={`group relative flex w-full cursor-pointer items-center gap-1.5 rounded px-1.5 py-1 text-left transition-colors ${
          isSelected
            ? "bg-[#2C6BCB]/55 text-white shadow-[inset_0_1px_0_rgba(255,255,255,0.08)]"
            : "text-ink/90 hover:bg-white/[0.04]"
        }`}
      >
        <span className={`relative flex h-3.5 w-3.5 shrink-0 items-center justify-center ${iconColor}`}>
          {row.busy ? <Spinner size={12} /> : <Icon size={14} />}
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

        <span className="flex min-w-0 flex-1 flex-col items-start">
          <span className="flex items-center gap-1">
            <span className={`truncate text-[12.5px] ${isSelected ? "text-white" : "text-ink"}`}>
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
                isSelected ? "text-white/70" : "text-ink-muted"
              }`}
            >
              {row.branch}
            </span>
          )}
        </span>

        <span className="ml-auto flex shrink-0 items-center gap-1">
          {row.diff && (
            <span
              className={`rounded border px-1 py-[1px] font-mono text-[9.5px] tabular-nums ${
                isSelected ? "border-white/30 text-white/85" : "border-white/[0.10] text-ink-muted"
              }`}
            >
              {isSelected ? (
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

// ─── sidebar — Agents View panel ─────────────────────────────────────────

function ActiveAgentsSidebarPanel({
  onSelect,
  selected,
}: {
  onSelect: (id: string) => void;
  selected: string;
}) {
  const order: AgentState[] = ["waitingForInput", "finished", "loading", "idle"];
  const sorted = [...AGENTS].sort((a, b) => order.indexOf(a.state) - order.indexOf(b.state));
  return (
    <div className="relative flex h-full flex-col overflow-hidden rounded-t-[10px] border-x border-t border-white/[0.10] bg-white/[0.06] backdrop-blur-2xl shadow-[inset_0_1px_0_rgba(255,255,255,0.08)]">
      <div className="group/handle grid h-2 cursor-row-resize place-items-center">
        <span className="h-[3px] w-9 rounded-full bg-white/15 opacity-0 transition-opacity group-hover/handle:opacity-100" />
      </div>
      <div className="flex items-center gap-2 px-2.5 pb-1.5 pt-0.5">
        <span className="text-[11px] uppercase tracking-wider text-ink-muted">Agents View</span>
        <span className="font-mono text-[10.5px] text-ink-dim">({AGENTS.length})</span>
      </div>
      <div className="flex-1 overflow-y-auto">
        {sorted.map((a) => (
          <AgentRow
            key={a.id}
            a={a}
            focused={a.worktreeId === selected}
            onClick={() => onSelect(a.worktreeId)}
          />
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

function AgentRow({
  a,
  focused,
  onClick,
}: {
  a: AgentEntry;
  focused: boolean;
  onClick: () => void;
}) {
  const Logo = AGENT_LOGO[a.kind];
  return (
    <button
      type="button"
      onClick={onClick}
      className={`flex w-full cursor-pointer items-center gap-2 px-2.5 py-1.5 text-left transition-colors ${
        focused ? "bg-white/[0.10]" : "hover:bg-white/[0.04]"
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
    <div className="flex h-7 items-center border-t border-white/[0.06] bg-white/[0.03] px-1.5 backdrop-blur-xl">
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
          <rect x="2.5" y="5.5" width="9" height="6" rx="1.4" />
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
        active ? "text-leaf-100 bg-leaf-700/20" : "text-ink-muted hover:bg-white/[0.06] hover:text-ink"
      }`}
    >
      {children}
    </button>
  );
}

// ─── detail (right column body) ──────────────────────────────────────────

function Detail({ detail }: { detail: { tabs: TabConfig[]; panes: PaneConfig[] } }) {
  const [activeTab, setActiveTab] = useState<string>(() =>
    detail.tabs.find((t) => t.activeByDefault)?.id ?? detail.tabs[0]?.id ?? "",
  );

  // When the selected worktree changes the tabs swap; reset to the new
  // default. `key` on the tabbar would do the same with less control.
  const lastTabsRef = useRef(detail.tabs);
  useEffect(() => {
    if (lastTabsRef.current !== detail.tabs) {
      setActiveTab(detail.tabs.find((t) => t.activeByDefault)?.id ?? detail.tabs[0]?.id ?? "");
      lastTabsRef.current = detail.tabs;
    }
  }, [detail.tabs]);

  return (
    <div className="flex flex-col bg-[#0a0a0c]">
      <TabBar tabs={detail.tabs} activeTab={activeTab} onSelect={setActiveTab} />
      <PaneSplit panes={detail.panes} />
    </div>
  );
}

function TabBar({
  tabs,
  activeTab,
  onSelect,
}: {
  tabs: TabConfig[];
  activeTab: string;
  onSelect: (id: string) => void;
}) {
  return (
    <div className="flex h-9 items-end gap-0.5 border-b border-white/[0.06] bg-[#0e0e11] px-2 pt-1">
      {tabs.map((t) => {
        const active = t.id === activeTab;
        return (
          <button
            key={t.id}
            type="button"
            onClick={() => onSelect(t.id)}
            className={`group flex h-[30px] min-w-[92px] cursor-pointer items-center gap-1.5 rounded-t-md border border-b-0 px-2.5 font-mono text-[11.5px] transition-colors ${
              active
                ? "border-white/[0.10] bg-[#181820] text-ink"
                : "border-transparent text-ink-muted hover:bg-white/[0.04] hover:text-ink"
            }`}
          >
            {t.busy ? (
              <span className="text-leaf-300">
                <Spinner size={9} />
              </span>
            ) : (
              <span
                className={`h-1.5 w-1.5 rounded-full ${
                  t.dot ? "bg-[#FFA657]" : active ? "bg-leaf-300" : "bg-ink-dim/50"
                }`}
              />
            )}
            <span className="truncate">{t.title}</span>
            <span className="ml-1 text-ink-dim opacity-0 transition-opacity group-hover:opacity-100">
              ×
            </span>
          </button>
        );
      })}
      <button
        type="button"
        aria-label="New tab"
        title="New tab (⌘T)"
        className="ml-1 grid h-6 w-6 cursor-pointer place-items-center rounded text-ink-muted hover:bg-white/[0.05] hover:text-ink"
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

function PaneSplit({ panes }: { panes: PaneConfig[] }) {
  if (panes.length === 1) {
    return (
      <div className="flex-1">
        <PaneBody pane={panes[0]} />
      </div>
    );
  }
  return (
    <div className="grid flex-1 grid-cols-[1.25fr_1fr] gap-px bg-white/[0.06]">
      {panes.map((p, i) => (
        <PaneBody key={i} pane={p} />
      ))}
    </div>
  );
}

function PaneBody({ pane }: { pane: PaneConfig }) {
  return (
    <div className="relative bg-[#0a0a0c]">
      <div className="p-3 font-mono text-[11.5px] leading-[1.6] text-ink/85">
        {pane.lines.map((l, i) => {
          const isPrompt = l.startsWith("$");
          return (
            <div key={i}>
              {isPrompt ? (
                <>
                  <span className="text-leaf-300">{pane.prompt} </span>
                  <span className="text-ink">{l.slice(2)}</span>
                </>
              ) : (
                <span>{l}</span>
              )}
            </div>
          );
        })}
        {pane.waitingPrompt && (
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

// ─── menus ───────────────────────────────────────────────────────────────

/** Common "click-anywhere-to-dismiss" scrim. Sits below the menu but above
 *  the rest of the app so a click outside the menu closes it. */
function MenuScrim({ onDismiss }: { onDismiss: () => void }) {
  return (
    <button
      type="button"
      aria-label="Dismiss menu"
      onClick={onDismiss}
      className="absolute inset-0 z-40 cursor-default bg-transparent"
    />
  );
}

function FloatingMenu({
  children,
  style,
  className = "",
}: {
  children: React.ReactNode;
  style?: React.CSSProperties;
  className?: string;
}) {
  return (
    <motion.div
      initial={{ opacity: 0, y: -8, scale: 0.97 }}
      animate={{ opacity: 1, y: 0, scale: 1 }}
      exit={{ opacity: 0, y: -6, scale: 0.97 }}
      transition={{ duration: 0.18, ease: [0.22, 1, 0.36, 1] }}
      className={`absolute z-50 overflow-hidden rounded-[10px] border border-white/[0.10] bg-[#1c1c1f]/97 shadow-2xl backdrop-blur-2xl ${className}`}
      style={style}
    >
      {children}
    </motion.div>
  );
}

function MenuArrow({ rightOffset }: { rightOffset: number }) {
  return (
    <span
      aria-hidden
      className="absolute -top-[5px] h-3 w-3 rotate-45 border-l border-t border-white/[0.10] bg-[#1c1c1f]"
      style={{ right: rightOffset }}
    />
  );
}

// notifications popover ---------------------------------------------------

function NotificationsPopover({ onDismiss }: { onDismiss: () => void }) {
  const [filter, setFilter] = useState<"unread" | "all">("unread");
  const items = filter === "unread" ? NOTIFICATIONS.filter((n) => n.unread) : NOTIFICATIONS;
  return (
    <>
      <MenuScrim onDismiss={onDismiss} />
      <FloatingMenu className="top-[44px] right-[180px] w-[360px]">
        <MenuArrow rightOffset={48} />
        <div className="flex items-center justify-between border-b border-white/[0.06] px-3 py-2 font-mono text-[11.5px]">
          <div className="flex h-6 overflow-hidden rounded-md border border-white/[0.10] text-[11px]">
            <button
              type="button"
              onClick={() => setFilter("unread")}
              className={`grid cursor-pointer place-items-center px-2 transition-colors ${
                filter === "unread" ? "bg-white/[0.10] text-ink" : "text-ink-muted hover:bg-white/[0.04]"
              }`}
            >
              Unread
            </button>
            <button
              type="button"
              onClick={() => setFilter("all")}
              className={`grid cursor-pointer place-items-center px-2 transition-colors ${
                filter === "all" ? "bg-white/[0.10] text-ink" : "text-ink-muted hover:bg-white/[0.04]"
              }`}
            >
              All
            </button>
          </div>
          <button type="button" className="cursor-pointer text-[11px] text-ink-muted hover:text-ink">
            Mark all read
          </button>
        </div>
        <ul className="max-h-[280px] overflow-y-auto">
          {items.length === 0 ? (
            <li className="py-10 text-center text-[12px] text-ink-muted">No notifications</li>
          ) : (
            items.map((n) => <NotifRow key={n.id} n={n} />)
          )}
        </ul>
      </FloatingMenu>
    </>
  );
}

function NotifRow({ n }: { n: NotificationItem }) {
  return (
    <li>
      <button
        type="button"
        className="flex w-full items-start gap-2.5 border-b border-white/[0.04] px-3 py-2.5 text-left transition-colors hover:bg-white/[0.04]"
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

// open-in menu ------------------------------------------------------------

function OpenInMenu({ onDismiss }: { onDismiss: () => void }) {
  return (
    <>
      <MenuScrim onDismiss={onDismiss} />
      <FloatingMenu className="top-[44px] right-[42px] w-[240px]">
        <MenuArrow rightOffset={20} />
        <ul className="py-1.5">
          {EDITOR_CHOICES.map((e) => (
            <EditorRow key={e.id} e={e} />
          ))}
          <MenuDivider />
          <PlainRow icon={<Folder size={13} />} label="Reveal in Finder" chord="⌘⇧R" />
          <MenuDivider />
          <PlainRow icon={<Plus size={12} />} label="Custom editors…" muted />
        </ul>
      </FloatingMenu>
    </>
  );
}

function EditorRow({ e }: { e: EditorChoice }) {
  return (
    <li>
      <button
        type="button"
        disabled={!e.installed}
        title={e.reason}
        className={`flex w-full items-center gap-2 px-3 py-1.5 text-left transition-colors ${
          e.installed
            ? "cursor-pointer text-ink hover:bg-white/[0.06]"
            : "cursor-not-allowed text-ink-dim"
        }`}
      >
        <EditorGlyph id={e.id} />
        <span className="text-[12.5px]">{e.name}</span>
        {!e.installed && (
          <span className="ml-1 text-[10.5px] text-ink-dim">(not found)</span>
        )}
        {e.chord && (
          <span className="ml-auto font-mono text-[10.5px] text-ink-muted">{e.chord}</span>
        )}
      </button>
    </li>
  );
}

// run-script menu ---------------------------------------------------------

function RunScriptMenu({ onDismiss }: { onDismiss: () => void }) {
  return (
    <>
      <MenuScrim onDismiss={onDismiss} />
      <FloatingMenu className="top-[44px] right-[112px] w-[240px]">
        <MenuArrow rightOffset={20} />
        <ul className="py-1.5">
          {RUN_SCRIPTS.map((s) => (
            <ScriptRow key={s.id} s={s} />
          ))}
          <MenuDivider />
          <PlainRow icon={<Plus size={12} />} label="New script…" muted />
        </ul>
      </FloatingMenu>
    </>
  );
}

function ScriptRow({ s }: { s: RunScript }) {
  return (
    <li>
      <button
        type="button"
        className="flex w-full cursor-pointer items-center gap-2 px-3 py-1.5 text-left text-ink transition-colors hover:bg-white/[0.06]"
      >
        <svg width="11" height="11" viewBox="0 0 16 16" fill="currentColor" className="text-leaf-300">
          <path d="M4 3l9 5-9 5V3z" />
        </svg>
        <span className="text-[12.5px]">{s.name}</span>
        <span className="ml-2 font-mono text-[10.5px] text-ink-dim">{s.command}</span>
        {s.chord && (
          <span className="ml-auto font-mono text-[10.5px] text-ink-muted">{s.chord}</span>
        )}
      </button>
    </li>
  );
}

// menu shared --------------------------------------------------------------

function MenuDivider() {
  return <li role="separator" className="my-1 h-px bg-white/[0.06]" />;
}

function PlainRow({
  icon,
  label,
  chord,
  muted,
}: {
  icon: React.ReactNode;
  label: string;
  chord?: string;
  muted?: boolean;
}) {
  return (
    <li>
      <button
        type="button"
        className={`flex w-full cursor-pointer items-center gap-2 px-3 py-1.5 text-left transition-colors hover:bg-white/[0.06] ${
          muted ? "text-ink-muted" : "text-ink"
        }`}
      >
        <span className="text-ink-muted">{icon}</span>
        <span className="text-[12.5px]">{label}</span>
        {chord && (
          <span className="ml-auto font-mono text-[10.5px] text-ink-muted">{chord}</span>
        )}
      </button>
    </li>
  );
}

// ─── overlays — command palette ─────────────────────────────────────────

function CommandPaletteOverlay({ onDismiss }: { onDismiss: () => void }) {
  const [q, setQ] = useState("open");
  const filtered = COMMANDS.filter(
    (c) =>
      c.title.toLowerCase().includes(q.toLowerCase()) ||
      c.subtitle?.toLowerCase().includes(q.toLowerCase()),
  );
  const [sel, setSel] = useState(0);
  useEffect(() => {
    setSel(0);
  }, [q]);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onDismiss();
      if (e.key === "ArrowDown") setSel((s) => Math.min(s + 1, filtered.length - 1));
      if (e.key === "ArrowUp") setSel((s) => Math.max(s - 1, 0));
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [filtered.length, onDismiss]);

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      transition={{ duration: 0.18 }}
      onClick={onDismiss}
      className="absolute inset-0 z-50 grid place-items-start bg-black/30 pt-14 backdrop-blur-[2px]"
    >
      <motion.div
        initial={{ y: -10, scale: 0.98, opacity: 0 }}
        animate={{ y: 0, scale: 1, opacity: 1 }}
        exit={{ y: -6, scale: 0.98, opacity: 0 }}
        transition={{ duration: 0.22, ease: [0.22, 1, 0.36, 1] }}
        onClick={(e) => e.stopPropagation()}
        className="mx-auto w-[560px] overflow-hidden rounded-[12px] border border-white/[0.10] bg-[#1c1c1f]/95 shadow-2xl backdrop-blur-2xl"
      >
        <div className="flex h-12 items-center gap-2 border-b border-white/[0.06] px-3.5 text-ink-muted">
          <Search size={14} />
          <input
            autoFocus
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Quick action…"
            className="flex-1 bg-transparent font-mono text-[14px] text-ink outline-none placeholder:text-ink-dim"
          />
          <span className="rounded border border-white/[0.10] px-1.5 font-mono text-[10px] text-ink-dim">
            ⎋ esc
          </span>
        </div>
        <ul className="max-h-[300px] overflow-y-auto p-1.5">
          {filtered.length === 0 ? (
            <li className="py-8 text-center text-[12.5px] text-ink-muted">No matching commands.</li>
          ) : (
            filtered.map((c, i) => (
              <CommandRow key={c.id} c={c} selected={i === sel} onHover={() => setSel(i)} />
            ))
          )}
        </ul>
      </motion.div>
    </motion.div>
  );
}

function CommandRow({
  c,
  selected,
  onHover,
}: {
  c: CommandItem;
  selected: boolean;
  onHover: () => void;
}) {
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
        onMouseEnter={onHover}
        className={`flex w-full items-center gap-2.5 rounded-md px-2.5 py-2 transition-colors ${
          selected ? "bg-[#2C6BCB] text-white" : "text-ink hover:bg-white/[0.05]"
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
            className={`font-mono text-[11px] ${selected ? "text-white/85" : "text-ink-muted"}`}
          >
            {c.chord}
          </span>
        )}
      </button>
    </li>
  );
}
