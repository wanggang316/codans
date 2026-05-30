import { useTranslation } from "react-i18next";
import { motion } from "framer-motion";

/**
 * §3 — Many projects, one window. The right column renders a stylised
 * triptych: three Project cards side-by-side, each with its own
 * Worktree list. The composition mirrors the sidebar from the hero
 * screenshot at a different scale, so the visitor reads "every one of
 * these is a Project, not a Finder window".
 */

interface WorktreeRow {
  name: string;
  pr?: { number: number; state: "open" | "draft" | "merged" | "closed" };
  active?: boolean;
  busy?: boolean;
  diff?: string;
}

interface ProjectCard {
  name: string;
  worktrees: WorktreeRow[];
}

const PROJECTS: ProjectCard[] = [
  {
    name: "touch-code",
    worktrees: [
      { name: "main" },
      { name: "fix/git-bug", pr: { number: 81, state: "merged" }, active: true },
      { name: "feature/website" },
      { name: "feat/script-style", diff: "+212 −181" },
    ],
  },
  {
    name: "you-skill",
    worktrees: [
      { name: "main" },
      { name: "feat/batch-update", pr: { number: 12, state: "open" }, busy: true },
      { name: "wip/import" },
    ],
  },
  {
    name: "nanops",
    worktrees: [
      { name: "main", active: true },
      { name: "fix/caddy", pr: { number: 4, state: "draft" } },
    ],
  },
];

const PR_BADGE: Record<NonNullable<WorktreeRow["pr"]>["state"], string> = {
  open: "bg-[#102818]/80 text-[#7EE0A0] border-[#1F5F33]",
  draft: "bg-[#1A1D22]/80 text-[#B0B7BE] border-[#373E47]",
  merged: "bg-[#2A1F4A]/80 text-[#D2B7FF] border-[#6E40C9]/60",
  closed: "bg-[#2E1418]/80 text-[#FFA8A6] border-[#8E2D2D]",
};

const PR_TINT: Record<NonNullable<WorktreeRow["pr"]>["state"], string> = {
  open: "text-[#3FB950]",
  draft: "text-[#8B949E]",
  merged: "text-[#A371F7]",
  closed: "text-[#F85149]",
};

export default function MultiProject() {
  const { t } = useTranslation();
  return (
    <section className="relative border-t border-line/60 bg-bg py-28 sm:py-36">
      <div className="mx-auto grid max-w-[1200px] items-center gap-16 px-5 sm:px-8 lg:grid-cols-[1fr_1.15fr]">
        {/* Left — copy */}
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.7, ease: [0.22, 1, 0.36, 1] }}
        >
          <h2 className="font-mono text-display-2 font-bold text-ink">
            {t("multi_project.title")}
          </h2>
          <p className="mt-5 text-[17px] leading-relaxed text-ink-muted">
            {t("multi_project.lead")}
          </p>
          <div className="mt-6 inline-flex items-center gap-2 rounded-full border border-wx-500/30 bg-wx-500/[0.08] px-3 py-1.5 font-mono text-[12px] text-wx-200">
            <span className="h-1.5 w-1.5 rounded-full bg-wx-500 animate-breathe" />
            {t("multi_project.stat")}
          </div>
        </motion.div>

        {/* Right — animated triptych */}
        <motion.div
          initial={{ opacity: 0, y: 30 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.9, delay: 0.1, ease: [0.22, 1, 0.36, 1] }}
          className="relative"
        >
          <ProjectTriptych />
        </motion.div>
      </div>
    </section>
  );
}

function ProjectTriptych() {
  return (
    <div className="relative grid grid-cols-3 gap-3">
      {PROJECTS.map((p, i) => (
        <motion.div
          key={p.name}
          initial={{ opacity: 0, y: 14 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-60px" }}
          transition={{ duration: 0.6, delay: 0.15 + i * 0.12, ease: [0.22, 1, 0.36, 1] }}
          className="relative overflow-hidden rounded-[10px] border border-white/[0.08] bg-bg-elev/80 backdrop-blur-sm shadow-[0_18px_40px_-20px_rgba(0,0,0,0.7)]"
          style={{ transform: `translateY(${i === 1 ? "-12px" : i === 2 ? "-4px" : "0"})` }}
        >
          <ProjectMiniCard p={p} delay={0.3 + i * 0.12} />
        </motion.div>
      ))}

      {/* Connecting line at top — implies "same workspace" without
          drawing an actual root node. */}
      <svg
        aria-hidden
        viewBox="0 0 600 40"
        preserveAspectRatio="none"
        className="absolute -top-7 left-0 right-0 h-7 w-full"
      >
        <motion.path
          d="M 50 36 Q 200 4 300 4 Q 400 4 550 36"
          stroke="rgba(7,193,96,0.35)"
          strokeWidth="1.4"
          fill="none"
          strokeDasharray="4 4"
          initial={{ pathLength: 0 }}
          whileInView={{ pathLength: 1 }}
          viewport={{ once: true }}
          transition={{ duration: 1.2, delay: 0.6 }}
        />
        <motion.circle
          cx="300"
          cy="4"
          r="3"
          fill="#07C160"
          initial={{ scale: 0 }}
          whileInView={{ scale: 1 }}
          viewport={{ once: true }}
          transition={{ duration: 0.4, delay: 0.9 }}
        />
      </svg>
    </div>
  );
}

function ProjectMiniCard({ p, delay }: { p: ProjectCard; delay: number }) {
  return (
    <div className="flex flex-col">
      {/* header */}
      <div className="flex items-center gap-1.5 border-b border-white/[0.06] bg-white/[0.02] px-2.5 py-2 font-mono text-[11px] text-ink">
        <FolderGlyph />
        <span className="truncate">{p.name}</span>
      </div>
      {/* worktrees */}
      <ul className="flex flex-col px-1.5 py-1.5">
        {p.worktrees.map((w, i) => (
          <motion.li
            key={w.name}
            initial={{ opacity: 0, x: -6 }}
            whileInView={{ opacity: 1, x: 0 }}
            viewport={{ once: true }}
            transition={{ duration: 0.35, delay: delay + i * 0.05 }}
            className={`group flex items-center gap-1.5 rounded px-1.5 py-1 text-[11px] ${
              w.active ? "bg-[#2C6BCB]/45 text-white" : "text-ink/90"
            }`}
          >
            {/* leading icon */}
            <span
              className={`relative grid h-3 w-3 shrink-0 place-items-center ${
                w.pr ? PR_TINT[w.pr.state] : "text-ink-muted"
              }`}
            >
              {w.busy ? <Spinner /> : w.pr ? <PRGlyph /> : <BranchGlyph />}
            </span>
            <span className="flex-1 truncate font-mono text-[10.5px]">{w.name}</span>
            {w.diff && (
              <span className="font-mono text-[9px] tabular-nums text-ink-muted">
                {w.diff}
              </span>
            )}
            {w.pr && (
              <span
                className={`rounded border px-1 py-[1px] font-mono text-[9px] tabular-nums ${PR_BADGE[w.pr.state]}`}
              >
                #{w.pr.number}
              </span>
            )}
          </motion.li>
        ))}
      </ul>
    </div>
  );
}

function FolderGlyph() {
  return (
    <svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.3" className="text-ink-muted">
      <path d="M2 4a1 1 0 011-1h3l1.5 1.5H13a1 1 0 011 1v6a1 1 0 01-1 1H3a1 1 0 01-1-1V4z" strokeLinejoin="round" />
    </svg>
  );
}

function BranchGlyph() {
  // Octicons git-branch silhouette (matches the asset shipped at /icons/git-branch.svg)
  return (
    <svg width="11" height="11" viewBox="0 0 16 16" fill="currentColor">
      <path d="M9.5 3.25a2.25 2.25 0 113 2.122V6A2.5 2.5 0 0110 8.5H6a1 1 0 00-1 1v1.128a2.251 2.251 0 11-1.5 0V5.372a2.25 2.25 0 111.5 0v1.836A2.493 2.493 0 016 7h4a1 1 0 001-1v-.628A2.25 2.25 0 019.5 3.25Zm-6.5 0a1.25 1.25 0 102.5 0 1.25 1.25 0 00-2.5 0Zm8.75-1.25a1.25 1.25 0 100 2.5 1.25 1.25 0 000-2.5ZM4.25 11.5a1.25 1.25 0 100 2.5 1.25 1.25 0 000-2.5Z" />
    </svg>
  );
}

function PRGlyph() {
  return (
    <svg width="11" height="11" viewBox="0 0 16 16" fill="currentColor">
      <path d="M1.5 3.25a2.25 2.25 0 113 2.122v5.256a2.251 2.251 0 11-1.5 0V5.372A2.25 2.25 0 011.5 3.25Zm5.677-.177L9.573.677A.25.25 0 0110 .854V2.5h1A2.5 2.5 0 0113.5 5v5.628a2.251 2.251 0 11-1.5 0V5a1 1 0 00-1-1h-1v1.646a.25.25 0 01-.427.177L7.177 3.427a.25.25 0 010-.354ZM3.75 2.5a.75.75 0 100 1.5.75.75 0 000-1.5Zm0 9.5a.75.75 0 100 1.5.75.75 0 000-1.5Zm8.25.75a.75.75 0 101.5 0 .75.75 0 00-1.5 0Z" />
    </svg>
  );
}

function Spinner() {
  return (
    <span className="inline-block h-2.5 w-2.5 animate-spin rounded-full border-[1.2px] border-wx-500/40 border-t-wx-500" />
  );
}
