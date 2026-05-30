import { useTranslation } from "react-i18next";
import { motion } from "framer-motion";

/**
 * §5 — Five extensibility surfaces, rendered as a bento grid with one
 * tall hero cell (Agents View) and four smaller cells around it. Each
 * cell carries a different visual treatment so the bento doesn't
 * collapse into the white-on-white text-cards anti-pattern.
 */
export default function Extensions() {
  const { t } = useTranslation();
  return (
    <section className="relative border-t border-line/60 bg-bg py-28 sm:py-36">
      <div className="mx-auto max-w-[1200px] px-5 sm:px-8">
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.7 }}
          className="max-w-[680px]"
        >
          <h2 className="font-mono text-display-2 font-bold text-ink">
            {t("extensions.title")}
          </h2>
          <p className="mt-5 text-[17px] leading-relaxed text-ink-muted">
            {t("extensions.lead")}
          </p>
        </motion.div>

        <div className="mt-14 grid auto-rows-[minmax(0,1fr)] gap-3 sm:gap-4 lg:grid-cols-3">
          {/* Hero cell — Agents View, 2-col x 1-row on desktop */}
          <BentoCell
            title={t("extensions.cards.agents.title")}
            body={t("extensions.cards.agents.body")}
            delay={0}
            className="lg:col-span-2 lg:row-span-2"
            preview={<AgentsPreview />}
          />
          <BentoCell
            title={t("extensions.cards.commands.title")}
            body={t("extensions.cards.commands.body")}
            delay={0.08}
            className="lg:col-span-1 lg:row-span-1"
            preview={<CommandsPreview />}
          />
          <BentoCell
            title={t("extensions.cards.pr.title")}
            body={t("extensions.cards.pr.body")}
            delay={0.16}
            className="lg:col-span-1 lg:row-span-1"
            preview={<PrStatusPreview />}
          />
          <BentoCell
            title={t("extensions.cards.ide.title")}
            body={t("extensions.cards.ide.body")}
            delay={0.24}
            className="lg:col-span-1 lg:row-span-1"
            preview={<IdePreview />}
          />
          <BentoCell
            title={t("extensions.cards.git.title")}
            body={t("extensions.cards.git.body")}
            delay={0.32}
            className="lg:col-span-2 lg:row-span-1"
            preview={<GitViewerPreview />}
          />
        </div>
      </div>
    </section>
  );
}

// ─── cell shell ─────────────────────────────────────────────────────────

function BentoCell({
  title,
  body,
  preview,
  className = "",
  delay = 0,
}: {
  title: string;
  body: string;
  preview: React.ReactNode;
  className?: string;
  delay?: number;
}) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 18 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: "-80px" }}
      transition={{ duration: 0.6, delay, ease: [0.22, 1, 0.36, 1] }}
      whileHover={{ y: -2 }}
      className={`group relative flex flex-col overflow-hidden rounded-[12px] border border-white/[0.06] bg-bg-elev/60 backdrop-blur-sm transition-colors hover:border-wx-500/30 ${className}`}
    >
      {/* preview region */}
      <div className="relative flex-1 overflow-hidden border-b border-white/[0.04]">
        {preview}
      </div>
      {/* text region */}
      <div className="flex flex-col gap-1.5 p-5">
        <h3 className="font-mono text-[14px] font-semibold text-ink">{title}</h3>
        <p className="text-[12.5px] leading-relaxed text-ink-muted">{body}</p>
      </div>
    </motion.div>
  );
}

// ─── previews ───────────────────────────────────────────────────────────

function AgentsPreview() {
  const agents = [
    { kind: "claude", project: "touch-code", worktree: "fix/race-cond", state: "waiting", verbColor: "text-[#FFA657]" },
    { kind: "codex", project: "touch-code", worktree: "feat/agent-loop", state: "working", verbColor: "text-ink" },
    { kind: "pi", project: "you-skill", worktree: "feat/batch-update", state: "finished", verbColor: "text-wx-300" },
    { kind: "opencode", project: "nanops", worktree: "fix/caddy", state: "idle", verbColor: "text-ink-muted" },
  ];
  return (
    <div className="relative flex h-full min-h-[280px] flex-col bg-[#0c0c0e] p-3">
      <div className="mb-2 px-1 font-mono text-[10px] uppercase tracking-wider text-ink-muted">
        Agents View · 4
      </div>
      <ul className="space-y-px">
        {agents.map((a, i) => (
          <motion.li
            key={i}
            initial={{ opacity: 0, x: -6 }}
            whileInView={{ opacity: 1, x: 0 }}
            viewport={{ once: true }}
            transition={{ duration: 0.4, delay: 0.2 + i * 0.07 }}
            className="flex items-center gap-2 rounded px-2 py-2 hover:bg-white/[0.04]"
          >
            <AgentMark kind={a.kind} />
            <span className="flex min-w-0 flex-1 flex-col">
              <span className="truncate font-mono text-[11px] text-ink">{a.worktree}</span>
              <span className="truncate font-mono text-[10px] text-ink-muted">{a.project}</span>
            </span>
            <AgentStateBadge state={a.state} />
            <span className={`font-mono text-[10px] ${a.verbColor}`}>{a.state}</span>
          </motion.li>
        ))}
      </ul>
    </div>
  );
}

function AgentMark({ kind }: { kind: string }) {
  // Reference the real svgs shipped in public/icons/
  return (
    <span
      className="grid h-5 w-5 shrink-0 place-items-center text-ink-muted"
      style={{
        backgroundColor: "currentColor",
        width: 18,
        height: 18,
        maskImage: `url(/icons/${kind === "claude" ? "claude-code" : kind}.svg)`,
        WebkitMaskImage: `url(/icons/${kind === "claude" ? "claude-code" : kind}.svg)`,
        maskSize: "contain",
        WebkitMaskSize: "contain",
        maskRepeat: "no-repeat",
        WebkitMaskRepeat: "no-repeat",
        maskPosition: "center",
        WebkitMaskPosition: "center",
      }}
    />
  );
}

function AgentStateBadge({ state }: { state: string }) {
  if (state === "waiting") {
    return (
      <span className="text-[#FFA657]">
        <svg width="10" height="10" viewBox="0 0 16 16" fill="currentColor">
          <rect x="4" y="3.5" width="2.6" height="9" rx="0.6" />
          <rect x="9.4" y="3.5" width="2.6" height="9" rx="0.6" />
        </svg>
      </span>
    );
  }
  if (state === "working") {
    return (
      <span className="grid grid-cols-3 gap-[1.5px]">
        {Array.from({ length: 9 }).map((_, i) => (
          <span
            key={i}
            className="h-[3px] w-[3px] bg-ink"
            style={{
              animation: `loading-grid-cell 3s linear ${0.2 + (i % 3) * 0.2 + Math.floor(i / 3) * 0.6}s infinite`,
            }}
          />
        ))}
        <style>{`
          @keyframes loading-grid-cell {
            0% { opacity: 1; }
            90% { opacity: 0; }
            100% { opacity: 0; }
          }
        `}</style>
      </span>
    );
  }
  if (state === "finished") {
    return (
      <span className="text-wx-400">
        <svg width="10" height="10" viewBox="0 0 16 16" fill="currentColor">
          <circle cx="8" cy="8" r="7" />
          <path d="M4.6 8.2 7.0 10.6 11.4 5.6" stroke="#0a0a0c" strokeWidth="1.8" fill="none" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </span>
    );
  }
  return (
    <span className="text-ink-dim">
      <svg width="10" height="10" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3">
        <circle cx="8" cy="8" r="6" strokeDasharray="2 2" />
      </svg>
    </span>
  );
}

function CommandsPreview() {
  const rows = [
    { icon: "+", label: "New Worktree…", chord: "⌘N" },
    { icon: "↗", label: "Open in VS Code", chord: "⌘E" },
    { icon: "📖", label: "Toggle Git Viewer", chord: "⌘⌥G" },
  ];
  return (
    <div className="flex h-full min-h-[180px] flex-col bg-[#0c0c0e] p-3">
      <div className="mb-2 flex items-center gap-1.5 rounded-md border border-white/[0.06] bg-white/[0.03] px-2 py-1.5 font-mono text-[10.5px] text-ink-muted">
        <span>⌘</span>
        <span className="text-ink-dim">Quick action…</span>
      </div>
      <ul className="space-y-px">
        {rows.map((r, i) => (
          <motion.li
            key={i}
            initial={{ opacity: 0 }}
            whileInView={{ opacity: 1 }}
            viewport={{ once: true }}
            transition={{ duration: 0.4, delay: 0.2 + i * 0.07 }}
            className={`flex items-center gap-2 rounded px-2 py-1.5 font-mono text-[11px] ${
              i === 0 ? "bg-wx-500/15 text-wx-100" : "text-ink"
            }`}
          >
            <span className="w-3 text-ink-muted">{r.icon}</span>
            <span className="flex-1 truncate">{r.label}</span>
            <span className="text-[10px] text-ink-muted">{r.chord}</span>
          </motion.li>
        ))}
      </ul>
    </div>
  );
}

function PrStatusPreview() {
  return (
    <div className="flex h-full min-h-[180px] flex-col items-center justify-center bg-[#0c0c0e] p-4">
      <div className="flex items-center gap-3">
        <span className="inline-flex items-center gap-1 rounded border border-[#1F5F33] bg-[#102818]/80 px-2 py-0.5 font-mono text-[11px] text-[#7EE0A0]">
          #142
        </span>
        <PrRing />
      </div>
      <div className="mt-3 font-mono text-[11px] text-ink-muted">
        3/4 · <span className="text-ink">Mergeable</span>
      </div>
      <div className="mt-4 flex items-center gap-1.5 font-mono text-[10px] text-ink-dim">
        <span className="h-1.5 w-1.5 rounded-full bg-wx-500 animate-breathe" />
        gh api graphql · batched
      </div>
    </div>
  );
}

function PrRing() {
  // 3 green / 1 amber pending → 3/4 done
  return (
    <svg width="28" height="28" viewBox="-1 -1 22 22">
      <circle cx="10" cy="10" r="9" fill="none" stroke="#1F1F22" strokeWidth="3" />
      <path
        d="M 10 1 A 9 9 0 0 1 16.78 16.78"
        stroke="#3FB950"
        strokeWidth="3"
        fill="none"
      />
      <path
        d="M 16.78 16.78 A 9 9 0 0 1 10 19"
        stroke="#D29922"
        strokeWidth="3"
        fill="none"
      />
    </svg>
  );
}

function IdePreview() {
  const editors = [
    { id: "vscode", color: "#007ACC" },
    { id: "cursor", color: "#0E0E10" },
    { id: "zed", color: "#084CCC" },
    { id: "xcode", color: "#147EFB" },
    { id: "sublime", color: "#272822" },
  ];
  return (
    <div className="flex h-full min-h-[180px] flex-col items-center justify-center gap-3 bg-[#0c0c0e] p-4">
      <div className="flex items-center gap-2">
        {editors.map((e, i) => (
          <motion.span
            key={e.id}
            initial={{ opacity: 0, y: 4 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true }}
            transition={{ duration: 0.4, delay: 0.2 + i * 0.06 }}
            className="h-7 w-7 rounded-[6px] shadow-[0_4px_12px_-4px_rgba(0,0,0,0.6)] transition-transform hover:scale-110"
            style={{ background: e.color }}
            aria-label={e.id}
          />
        ))}
      </div>
      <div className="mt-1 font-mono text-[10.5px] text-ink-muted">
        Auto-detected · per-Project default
      </div>
    </div>
  );
}

function GitViewerPreview() {
  const lines = [
    { kind: "header", text: "apps/mac/.../StatusBarFeature.swift" },
    { kind: "minus", text: "-  if let toast = state.statusToast {" },
    { kind: "plus", text: "+  if let toast = state.toast, !toast.isStale {" },
    { kind: "context", text: "     return .toast(toast)" },
    { kind: "context", text: "   }" },
    { kind: "minus", text: "-  if let snap = gitHubStore.snapshots[wt] {" },
    { kind: "plus", text: "+  if let snap = gitHubStore.snapshots[wt], snap.state != .closed {" },
  ];
  return (
    <div className="flex h-full min-h-[200px] flex-col bg-[#0c0c0e] p-3 font-mono text-[10.5px] leading-[1.6]">
      <div className="mb-2 flex items-center justify-between border-b border-white/[0.06] pb-1.5 text-[10px] text-ink-muted">
        <span>git viewer · ⌘⌥G</span>
        <span><span className="text-wx-300">+24</span> <span className="text-[#F85149]">−12</span></span>
      </div>
      {lines.map((l, i) => {
        const cls =
          l.kind === "header" ? "text-ink-muted" :
          l.kind === "plus" ? "text-wx-200 bg-wx-500/[0.06]" :
          l.kind === "minus" ? "text-[#FFA8A6] bg-[#F85149]/[0.08]" :
          "text-ink/80";
        return (
          <motion.div
            key={i}
            initial={{ opacity: 0, x: -4 }}
            whileInView={{ opacity: 1, x: 0 }}
            viewport={{ once: true }}
            transition={{ duration: 0.35, delay: 0.15 + i * 0.04 }}
            className={`truncate px-1 ${cls}`}
          >
            {l.text}
          </motion.div>
        );
      })}
    </div>
  );
}
